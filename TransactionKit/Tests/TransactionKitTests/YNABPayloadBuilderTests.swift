import Foundation
import Testing
@testable import TransactionKit

@Suite("YNAB payload builder")
struct YNABPayloadBuilderTests {
    @Test("Amounts become milliunits and required create fields are explicit")
    func correctMilliunits() throws {
        let fixture = try addFixture(cents: -1_234)
        let prepared = build(
            fixture,
            selection: .init(rowID: "purchase", categoryID: "groceries", payee: "Market")
        )
        let transaction = try #require(prepared.request.transactions.first)

        #expect(transaction.amount == -12_340)
        #expect(transaction.date.description == "2026-09-14")
        #expect(transaction.memo == "Pushed by YNAB Reconciler iOS")
        #expect(transaction.approved)
        #expect(transaction.cleared == "cleared")

        let encoded = try JSONEncoder().encode(prepared.request)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("import_id"))
    }

    @Test("A shared amount is recomputed from purchase and repayment")
    func recomputesShare() throws {
        let fixture = try shareFixture()
        let prepared = build(
            fixture,
            selection: .init(rowID: "repayment", categoryID: "dining", payee: "Restaurant")
        )
        let transaction = try #require(prepared.request.transactions.first)

        #expect(transaction.amount == -6_000)
        #expect(transaction.date.description == "2026-09-10")
        #expect(transaction.cleared == "uncleared")
        #expect(prepared.sourceIDs == [["purchase", "repayment"]])
    }

    @Test("A row without a category is rejected")
    func rejectsMissingCategory() throws {
        let fixture = try addFixture()
        let prepared = build(
            fixture,
            selection: .init(rowID: "purchase", categoryID: nil, payee: "Market")
        )

        #expect(prepared.request.transactions.isEmpty)
        #expect(prepared.rejections == [.init(rowID: "purchase", reason: .missingCategory)])
    }

    @Test("An empty payee is rejected")
    func rejectsEmptyPayee() throws {
        let fixture = try addFixture()
        let prepared = build(
            fixture,
            selection: .init(rowID: "purchase", categoryID: "groceries", payee: "   ")
        )

        #expect(prepared.request.transactions.isEmpty)
        #expect(prepared.rejections == [.init(rowID: "purchase", reason: .emptyPayee)])
    }

    @Test("Payees longer than 200 characters are truncated")
    func truncatesPayee() throws {
        let fixture = try addFixture()
        let prepared = build(
            fixture,
            selection: .init(
                rowID: "purchase",
                categoryID: "groceries",
                payee: String(repeating: "é", count: 201)
            )
        )

        #expect(prepared.request.transactions.first?.payeeName.count == 200)
    }

    @Test("A logged id skips its entire row, including either id of a share")
    func skipsLoggedIDs() throws {
        let add = try addFixture()
        let skippedAdd = build(
            add,
            selection: .init(rowID: "purchase", categoryID: "groceries", payee: "Market"),
            pushedIDs: ["purchase"]
        )
        #expect(skippedAdd.request.transactions.isEmpty)
        #expect(skippedAdd.skippedLoggedRowIDs == ["purchase"])

        let share = try shareFixture()
        let skippedShare = build(
            share,
            selection: .init(rowID: "repayment", categoryID: "dining", payee: "Restaurant"),
            pushedIDs: ["purchase"]
        )
        #expect(skippedShare.request.transactions.isEmpty)
        #expect(skippedShare.skippedLoggedRowIDs == ["repayment"])
    }

    private func build(
        _ fixture: Fixture,
        selection: SendSelection,
        pushedIDs: Set<String> = []
    ) -> PreparedSend {
        YNABPayloadBuilder().build(
            reconciliation: fixture.reconciliation,
            upTransactions: fixture.up,
            selections: [selection],
            accountID: "account",
            heldStatus: "uncleared",
            pushedIDs: pushedIDs
        )
    }

    private func addFixture(cents: Int = -1_000) throws -> Fixture {
        let up = try decodeUp([
            upJSON(
                id: "purchase",
                status: "SETTLED",
                description: "Market",
                cents: cents,
                createdAt: "2026-09-14T21:30:00+10:00"
            )
        ])
        return Fixture(
            up: up,
            reconciliation: Reconciler().reconcile(
                up: up,
                ynab: [],
                parameters: ReconciliationParameters(partners: ["$partner"])
            )
        )
    }

    private func shareFixture() throws -> Fixture {
        let up = try decodeUp([
            upJSON(
                id: "purchase",
                status: "HELD",
                description: "Restaurant",
                cents: -1_000,
                createdAt: "2026-09-10T18:00:00+10:00"
            ),
            upJSON(
                id: "repayment",
                status: "SETTLED",
                description: "$partner",
                cents: 400,
                createdAt: "2026-09-11T09:00:00+10:00"
            )
        ])
        let reconciliation = Reconciler().reconcile(
            up: up,
            ynab: [],
            parameters: ReconciliationParameters(
                scoreFloor: 0,
                partners: ["$partner"],
                heldStatus: "uncleared",
                splitDecisions: ["repayment": .purchase(id: "purchase")]
            )
        )
        return Fixture(up: up, reconciliation: reconciliation)
    }

    private func decodeUp(_ transactions: [String]) throws -> [UpTransaction] {
        let json = #"{"data":[\#(transactions.joined(separator: ","))]}"#
        return try JSONDecoder().decode(UpResponse.self, from: Data(json.utf8)).data
    }

    private func upJSON(
        id: String,
        status: String,
        description: String,
        cents: Int,
        createdAt: String
    ) -> String {
        """
        {
          "id":"\(id)",
          "attributes":{
            "status":"\(status)",
            "description":"\(description)",
            "rawText":null,
            "transactionType":"Purchase",
            "createdAt":"\(createdAt)",
            "amount":{"valueInBaseUnits":\(cents)}
          },
          "relationships":{
            "category":{"data":null},
            "parentCategory":{"data":null}
          }
        }
        """
    }

    private struct Fixture {
        let up: [UpTransaction]
        let reconciliation: Reconciliation
    }
}
