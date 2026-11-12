import Foundation
import Testing
@testable import TransactionKit

/// Rules added after the golden fixtures, each reproducing a misclassification
/// seen in real data. The fixtures still pass unchanged: their anonymised
/// names never agree, so the name-first stages find nothing there.
@Suite("Engine rules")
struct EngineRulesTests {
    @Test("Agreeing names let a shared cost win over a same-amount purchase")
    func namesPromoteSharedCost() throws {
        // YNAB holds your half of each bill. Amount alone pairs the 12.00
        // coffee with the 12.00 snack-bar row and strands both halves.
        let up = try upTransactions([
            bank("coffee-bill", "Market Lane Coffee", -1200, "2026-11-05"),
            bank("coffee-repay", "$partner", 600, "2026-11-06"),
            bank("snack-bill", "SNKPK", -2400, "2026-11-07"),
            bank("snack-repay", "$partner", 1200, "2026-11-11")
        ])
        let ynab = try ynabTransactions([
            budget("y-coffee", "Market Lane", -6000, "2026-11-05"),
            budget("y-snack", "SNKPK", -12000, "2026-11-07")
        ])
        let result = Reconciler().reconcile(up: up, ynab: ynab, parameters: .init(partners: ["$partner"]))

        #expect(result.matched.isEmpty)
        #expect(Set(result.splitsInYNAB.map(\.ynabID)) == ["y-coffee", "y-snack"])
        #expect(result.splitsInYNAB.first { $0.ynabID == "y-snack" }?.purchaseID == "snack-bill")
        #expect(result.queries.isEmpty)
        #expect(result.shareBlocks.isEmpty)
        #expect(result.totals.identityHolds)
    }

    @Test("Without agreeing names, amount-only matching is unchanged")
    func unrelatedNamesStillMatchOnAmount() throws {
        let up = try upTransactions([bank("rent", "CommBank Savings", -428875, "2026-11-01")])
        let ynab = try ynabTransactions([budget("y-rent", "The Gladstone", -4288750, "2026-11-01")])
        let result = Reconciler().reconcile(up: up, ynab: ynab, parameters: .init(partners: ["$partner"]))

        #expect(result.matched.map(\.ynabID) == ["y-rent"])
    }

    @Test("Half repaid on a bill entered at full price asks for a correction")
    func repaymentOfFullPriceBill() throws {
        let up = try upTransactions([
            bank("dinner", "Don Tojo", -3050, "2026-11-07"),
            bank("repay", "$partner", 1525, "2026-11-11")
        ])
        let ynab = try ynabTransactions([budget("y-dinner", "Don Tojo", -30500, "2026-11-07")])
        let result = Reconciler().reconcile(up: up, ynab: ynab, parameters: .init(partners: ["$partner"]))

        let correction = try #require(result.amends.first)
        #expect(result.amends.count == 1)
        #expect(correction.ynabID == "y-dinner")
        #expect(correction.upID == "dinner")
        #expect(correction.repaymentID == "repay")
        #expect(correction.ynabCents == -3050)
        #expect(correction.upCents == -1525)
        #expect(correction.deltaCents == 1525)
        #expect(result.shareBlocks.isEmpty)
        #expect(result.adds.isEmpty)
        #expect(result.totals.identityHolds)
    }

    @Test("A convincing unentered bill keeps priority over a full-price correction")
    func unenteredBillWinsOverFullPrice() throws {
        let up = try upTransactions([
            bank("entered", "Gojo Events", -2400, "2026-11-01"),
            bank("unentered", "Tokyo Motto", -2400, "2026-11-10"),
            bank("repay", "$partner", 1200, "2026-11-11")
        ])
        let ynab = try ynabTransactions([budget("y-entered", "Gojo Events", -24000, "2026-11-01")])
        let result = Reconciler().reconcile(up: up, ynab: ynab, parameters: .init(partners: ["$partner"]))

        #expect(result.amends.isEmpty)
        #expect(result.shareBlocks.first?.chosenPurchaseID == "unentered")
        #expect(result.totals.identityHolds)
    }

    @Test("Only a partner can repay a bill in full")
    func fullRepaymentNeedsPartner() throws {
        let up = try upTransactions([
            bank("bill", "Bike Shop", -10000, "2026-11-02"),
            bank("saver", "Transfer from Holiday", 10000, "2026-11-03"),
            bank("bill-2", "Concert", -4500, "2026-11-04"),
            bank("partner", "$partner", 4500, "2026-11-05")
        ])
        let result = Reconciler().reconcile(up: up, ynab: [], parameters: .init(partners: ["$partner"]))

        #expect(result.repaid.map(\.creditID) == ["partner"])
        #expect(Set(result.adds.map(\.upID)) == ["bill", "saver"])
        #expect(result.totals.identityHolds)
    }

    @Test("A hold that settles for another amount corrects the pending entry")
    func heldAmountSettledDifferently() throws {
        let up = try upTransactions([
            bank("tab", "Bar Americano", -6900, "2026-11-08", heldCents: -6000)
        ])
        let ynab = try ynabTransactions([budget("y-tab", "Bar Americano", -60000, "2026-11-08")])
        let result = Reconciler().reconcile(up: up, ynab: ynab, parameters: .init(partners: ["$partner"]))

        let correction = try #require(result.amends.first)
        #expect(correction.ynabID == "y-tab")
        #expect(correction.deltaCents == -900)
        #expect(correction.repaymentID == nil)
        #expect(result.adds.isEmpty)
        #expect(result.queries.isEmpty)
        #expect(result.totals.identityHolds)
    }

    @Test("Payee names compare loosely")
    func payeeNameComparison() {
        #expect(PayeeNames.alike("Market Lane Coffee", "Market Lane"))
        #expect(PayeeNames.alike("Andrew's Hamburgers", "Andrew\u{2019}s Hamburguers"))
        #expect(PayeeNames.alike("SQ *COFFEE WEEKEND P,Melbourne", "Coffee Weekend"))
        #expect(PayeeNames.alike("Woolworths", "WOOLWORTHS"))
        #expect(!PayeeNames.alike("SQ *COFFEE WEEKEND P,Melbourne", "Diggy Doos Coffee"))
        #expect(!PayeeNames.alike("Market Lane Coffee", "SNKPK"))
        #expect(!PayeeNames.alike("CommBank Savings", "The Gladstone"))
    }

    // MARK: Builders

    private func bank(
        _ id: String,
        _ description: String,
        _ cents: Int,
        _ day: String,
        heldCents: Int? = nil
    ) -> String {
        let hold = heldCents.map { #","holdInfo":{"amount":{"valueInBaseUnits":\#($0)}}"# } ?? ""
        let type = cents > 0 ? "Deposit" : "Purchase"
        return #"{"id":"\#(id)","attributes":{"status":"SETTLED","description":"\#(description)","rawText":null,"transactionType":"\#(type)","createdAt":"\#(day)T12:00:00+11:00","amount":{"valueInBaseUnits":\#(cents)}\#(hold)}}"#
    }

    private func budget(_ id: String, _ payee: String, _ milliunits: Int, _ day: String) -> String {
        #"{"id":"\#(id)","date":"\#(day)","amount":\#(milliunits),"payee_name":"\#(payee)","cleared":"cleared","deleted":false}"#
    }

    private func upTransactions(_ items: [String]) throws -> [UpTransaction] {
        let json = #"{"data":[\#(items.joined(separator: ","))]}"#
        return try JSONDecoder().decode(UpResponse.self, from: Data(json.utf8)).data
    }

    private func ynabTransactions(_ items: [String]) throws -> [YNABTransaction] {
        let json = #"{"data":{"transactions":[\#(items.joined(separator: ","))]}}"#
        return try JSONDecoder().decode(YNABResponse.self, from: Data(json.utf8)).normalizedTransactions().values
    }
}
