import Foundation
import Testing
@testable import TransactionKit

@Suite("Reconciliation golden fixtures")
struct ReconcilerGoldenTests {
    @Test("Full fixture matches every expected classification and total")
    func fullFixture() throws {
        try assertFixture(up: "up", ynab: "ynab", expected: "expected")
    }

    @Test("Edge fixture matches every expected classification and total")
    func edgeFixture() throws {
        try assertFixture(up: "edge_up", ynab: "edge_ynab", expected: "edge_expected")
    }

    @Test("Up dates retain the timestamp's local calendar day")
    func upLocalDateDoesNotNormalizeToUTC() throws {
        let date = try LocalDate(upCreatedAt: "2026-09-14T23:30:00-10:00")
        #expect(date.description == "2026-09-14")
    }

    @Test("Local date differences handle leap years without calendar allocation")
    func localDateDifference() throws {
        let leapDay = try LocalDate(isoDate: "2024-02-29")
        let followingMarch = try LocalDate(isoDate: "2025-03-01")
        #expect(leapDay.days(to: followingMarch) == 366)
        #expect(followingMarch.days(to: leapDay) == -366)
    }

    @Test("Sub-cent YNAB conversion returns warning data")
    func conversionWarningIsData() {
        let result = Money.fromYNAB(milliunits: -12_345, transactionID: "example")
        #expect(result.money.cents == -1_235)
        #expect(result.warnings == [.subCentYNABAmount(transactionID: "example", milliunits: -12_345)])
    }

    @Test("An explicit split choice overrides a tied automatic shortlist")
    func explicitSplitChoice() throws {
        let actual = try reconcileEdge(splitDecisions: [
            "d24d7cf8-08dd-5091-9498-793708427e2d": .purchase(id: "a00311f5-d026-5c8a-a5f0-df6b80fce7d4")
        ])
        let block = try #require(actual.shareBlocks.first {
            $0.depositID == "d24d7cf8-08dd-5091-9498-793708427e2d"
        })

        #expect(block.chosenPurchaseID == "a00311f5-d026-5c8a-a5f0-df6b80fce7d4")
        #expect(block.yourShareCents == -2_500)
        #expect(actual.totals.identityHolds)
    }

    @Test("Not a split returns both transactions to separate actions")
    func rejectedSplit() throws {
        let depositID = "6cd4c2cb-375b-5a8a-b3c4-d2c67ae18d3b"
        let purchaseID = "6507d976-006e-58ed-b3f9-2e23cb4719e8"
        let actual = try reconcileEdge(splitDecisions: [depositID: .notASplit])

        #expect(!actual.shareBlocks.contains { $0.depositID == depositID })
        #expect(actual.adds.contains { $0.upID == depositID })
        #expect(actual.adds.contains { $0.upID == purchaseID })
        #expect(actual.totals.identityHolds)
    }

    @Test("Cancellable reconciliation reports all passes in order")
    func reconciliationProgress() throws {
        let decoder = JSONDecoder()
        let up = try decoder.decode(UpResponse.self, from: resource(named: "edge_up"))
        let ynab = try decoder.decode(YNABResponse.self, from: resource(named: "edge_ynab"))
        let recorder = ReconciliationProgressRecorder()

        _ = try Reconciler().reconcileCancellable(
            up: up.data,
            ynab: ynab.normalizedTransactions().values,
            parameters: .init(partners: ["$partner_handle"], heldStatus: "cleared")
        ) { recorder.append($0) }

        let values = recorder.values
        let passOrder = values.reduce(into: [ReconciliationProgress.Pass]()) { passes, value in
            if passes.last != value.pass {
                passes.append(value.pass)
            }
        }
        #expect(passOrder == [
            .directMatches,
            .reversals,
            .existingSplits,
            .sharedCosts,
            .repayments,
            .corrections
        ])
        #expect(values.allSatisfy { (0...100).contains($0.percentComplete) })
        #expect(values.last?.percentComplete == 100)
    }

    @Test("An unresolved shared repayment cannot be consumed again by pass five")
    func unresolvedShareRepaymentIsClaimed() throws {
        let data = Data(#"""
        {"data":[
          {"id":"purchase-a","attributes":{"status":"SETTLED","description":"Shop A","rawText":null,"transactionType":"Purchase","createdAt":"2026-09-01T10:00:00+10:00","amount":{"valueInBaseUnits":-10000}}},
          {"id":"purchase-b","attributes":{"status":"SETTLED","description":"Shop B","rawText":null,"transactionType":"Purchase","createdAt":"2026-09-01T10:00:00+10:00","amount":{"valueInBaseUnits":-10000}}},
          {"id":"other-debit","attributes":{"status":"SETTLED","description":"Other","rawText":null,"transactionType":"Purchase","createdAt":"2026-09-02T10:00:00+10:00","amount":{"valueInBaseUnits":-5000}}},
          {"id":"repayment","attributes":{"status":"SETTLED","description":"$partner_handle","rawText":null,"transactionType":"Transfer","createdAt":"2026-09-02T10:00:00+10:00","amount":{"valueInBaseUnits":5000}}}
        ]}
        """#.utf8)
        let up = try JSONDecoder().decode(UpResponse.self, from: data)
        let actual = Reconciler().reconcile(
            up: up.data,
            ynab: [],
            parameters: .init(partners: ["$partner_handle"])
        )

        let block = try #require(actual.shareBlocks.first { $0.depositID == "repayment" })
        #expect(block.tied)
        #expect(block.chosenPurchaseID == nil)
        #expect(actual.repaid.isEmpty)
        #expect(actual.adds.contains { $0.upID == "other-debit" })
        #expect(actual.totals.identityHolds)
    }

    private func assertFixture(up upName: String, ynab ynabName: String, expected expectedName: String) throws {
        let decoder = JSONDecoder()
        let up = try decoder.decode(UpResponse.self, from: resource(named: upName))
        let ynabResponse = try decoder.decode(YNABResponse.self, from: resource(named: ynabName))
        let expected = try decoder.decode(Expected.self, from: resource(named: expectedName))
        let normalized = ynabResponse.normalizedTransactions()
        let parameters = ReconciliationParameters(
            tolerance: expected.parameters.tolerance,
            reimbursementWindow: expected.parameters.reimbursementWindow,
            settleWindow: expected.parameters.settleWindow,
            amendToleranceCents: expected.parameters.amendToleranceCents,
            amendDays: expected.parameters.amendDays,
            partners: expected.parameters.partners,
            heldStatus: expected.parameters.heldStatus
        )
        let actual = Reconciler().reconcile(
            up: up.data,
            ynab: normalized.values,
            parameters: parameters
        )

        #expect(actual.inputCounts.up == expected.counts.up)
        #expect(actual.inputCounts.ynab == expected.counts.ynab)
        #expect(actual.matched == expected.matched.map(\.value))
        #expect(actual.reversals == expected.reversals.map(\.value))
        #expect(actual.splitsInYNAB == expected.splitsInYNAB.map(\.value))
        #expect(actual.repaid == expected.repaid.map(\.value))
        #expect(actual.shareBlocks == expected.shareBlocks.map(\.value))
        #expect(actual.amends == expected.amends.map(\.value))
        #expect(actual.adds == expected.adds.map(\.value))
        #expect(actual.queries == expected.queries.map(\.value))

        #expect(actual.matched.count == expected.counts.matched)
        #expect(actual.reversals.count == expected.counts.reversals)
        #expect(actual.splitsInYNAB.count == expected.counts.splitsInYNAB)
        #expect(actual.repaid.count == expected.counts.repaid)
        #expect(actual.shareBlocks.count == expected.counts.shareBlocks)
        #expect(actual.shareBlocks.filter { $0.chosenPurchaseID != nil }.count == expected.counts.shareBlocksPreselected)
        #expect(actual.shareBlocks.filter(\.tied).count == expected.counts.shareBlocksTied)
        #expect(actual.amends.count == expected.counts.amends)
        #expect(actual.adds.count == expected.counts.adds)
        #expect(actual.queries.count == expected.counts.queries)

        #expect(actual.totals.upTotalCents == expected.totals.upTotalCents)
        #expect(actual.totals.ynabTotalCents == expected.totals.ynabTotalCents)
        #expect(actual.totals.gapCents == expected.totals.gapCents)
        #expect(actual.totals.addTotalCents == expected.totals.addTotalCents)
        #expect(actual.totals.shareTotalCents == expected.totals.shareTotalCents)
        #expect(actual.totals.unassignedRepaymentTotalCents == expected.totals.unassignedRepaymentTotalCents)
        #expect(actual.totals.amendTotalCents == expected.totals.amendTotalCents)
        #expect(actual.totals.queryTotalCents == expected.totals.queryTotalCents)
        #expect(actual.totals.identityHolds == expected.totals.identityHolds)

        // Independent form of SPEC §7, separate from ReconciliationTotals.identityHolds.
        let independentlyCalculatedActions = actual.adds.reduce(0) { $0 + $1.cents }
            + actual.shareBlocks.reduce(0) { $0 + ($1.yourShareCents ?? $1.depositCents) }
            + actual.amends.reduce(0) { $0 + $1.deltaCents }
            + actual.queries.reduce(0) { $0 - $1.cents }
        #expect(independentlyCalculatedActions == actual.totals.upTotalCents - actual.totals.ynabTotalCents)
    }

    private func resource(named name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "TestResources"))
        return try Data(contentsOf: url)
    }

    private func reconcileEdge(splitDecisions: [String: SplitDecision]) throws -> Reconciliation {
        let decoder = JSONDecoder()
        let up = try decoder.decode(UpResponse.self, from: resource(named: "edge_up"))
        let ynab = try decoder.decode(YNABResponse.self, from: resource(named: "edge_ynab"))
        return Reconciler().reconcile(
            up: up.data,
            ynab: ynab.normalizedTransactions().values,
            parameters: .init(
                partners: ["$partner_handle"],
                heldStatus: "cleared",
                splitDecisions: splitDecisions
            )
        )
    }
}

private final class ReconciliationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ReconciliationProgress] = []

    func append(_ progress: ReconciliationProgress) {
        lock.withLock {
            storage.append(progress)
        }
    }

    var values: [ReconciliationProgress] {
        lock.withLock { storage }
    }
}

private struct Expected: Decodable {
    let parameters: Parameters
    let totals: Totals
    let counts: Counts
    let matched: [ExpectedDirect]
    let reversals: [ExpectedZeroNet]
    let splitsInYNAB: [ExpectedExistingSplit]
    let repaid: [ExpectedZeroNet]
    let shareBlocks: [ExpectedShareBlock]
    let amends: [ExpectedCorrection]
    let adds: [ExpectedAdd]
    let queries: [ExpectedQuery]

    enum CodingKeys: String, CodingKey {
        case parameters, totals, counts, matched, reversals, repaid, amends, adds, queries
        case splitsInYNAB = "splits_in_ynab"
        case shareBlocks = "share_blocks"
    }

    struct Parameters: Decodable {
        let tolerance: Int
        let reimbursementWindow: Int
        let settleWindow: Int
        let amendToleranceCents: Int
        let amendDays: Int
        let partners: [String]
        let heldStatus: String

        enum CodingKeys: String, CodingKey {
            case tolerance, partners
            case reimbursementWindow = "reimbursement_window"
            case settleWindow = "settle_window"
            case amendToleranceCents = "amend_tolerance_cents"
            case amendDays = "amend_days"
            case heldStatus = "held_status"
        }
    }

    struct Totals: Decodable {
        let upTotalCents: Int
        let ynabTotalCents: Int
        let gapCents: Int
        let addTotalCents: Int
        let shareTotalCents: Int
        let unassignedRepaymentTotalCents: Int
        let amendTotalCents: Int
        let queryTotalCents: Int
        let identityHolds: Bool

        enum CodingKeys: String, CodingKey {
            case upTotalCents = "up_total_cents"
            case ynabTotalCents = "ynab_total_cents"
            case gapCents = "gap_cents"
            case addTotalCents = "add_total_cents"
            case shareTotalCents = "share_total_cents"
            case unassignedRepaymentTotalCents = "unassigned_repayment_total_cents"
            case amendTotalCents = "amend_total_cents"
            case queryTotalCents = "query_total_cents"
            case identityHolds = "identity_holds"
        }
    }

    struct Counts: Decodable {
        let up: Int
        let ynab: Int
        let matched: Int
        let reversals: Int
        let splitsInYNAB: Int
        let repaid: Int
        let shareBlocks: Int
        let shareBlocksPreselected: Int
        let shareBlocksTied: Int
        let amends: Int
        let adds: Int
        let queries: Int

        enum CodingKeys: String, CodingKey {
            case up, ynab, matched, reversals, repaid, amends, adds, queries
            case splitsInYNAB = "splits_in_ynab"
            case shareBlocks = "share_blocks"
            case shareBlocksPreselected = "share_blocks_preselected"
            case shareBlocksTied = "share_blocks_tied"
        }
    }
}

private struct ExpectedDirect: Decodable {
    let upID: String
    let ynabID: String
    let cents: Int
    let dayGap: Int
    var value: DirectMatch { .init(upID: upID, ynabID: ynabID, cents: cents, dayGap: dayGap) }

    enum CodingKeys: String, CodingKey {
        case cents
        case upID = "up_id"
        case ynabID = "ynab_id"
        case dayGap = "day_gap"
    }
}

private struct ExpectedZeroNet: Decodable {
    let purchaseID: String
    let creditID: String
    let cents: Int
    var value: ZeroNetPair { .init(purchaseID: purchaseID, creditID: creditID, cents: cents) }

    enum CodingKeys: String, CodingKey {
        case cents
        case purchaseID = "purchase_id"
        case creditID = "credit_id"
    }
}

private struct ExpectedExistingSplit: Decodable {
    let ynabID: String
    let purchaseID: String
    let depositID: String
    let yourShareCents: Int
    var value: ExistingSplit {
        .init(ynabID: ynabID, purchaseID: purchaseID, depositID: depositID, yourShareCents: yourShareCents)
    }

    enum CodingKeys: String, CodingKey {
        case ynabID = "ynab_id"
        case purchaseID = "purchase_id"
        case depositID = "deposit_id"
        case yourShareCents = "your_share_cents"
    }
}

private struct ExpectedShareBlock: Decodable {
    let depositID: String
    let depositCents: Int
    let chosenPurchaseID: String?
    let yourShareCents: Int?
    let tied: Bool
    let candidates: [ExpectedCandidate]
    var value: ShareBlock {
        .init(
            depositID: depositID,
            depositCents: depositCents,
            chosenPurchaseID: chosenPurchaseID,
            yourShareCents: yourShareCents,
            tied: tied,
            candidates: candidates.map(\.value)
        )
    }

    enum CodingKeys: String, CodingKey {
        case tied, candidates
        case depositID = "deposit_id"
        case depositCents = "deposit_cents"
        case chosenPurchaseID = "chosen_purchase_id"
        case yourShareCents = "your_share_cents"
    }
}

private struct ExpectedCandidate: Decodable {
    let purchaseID: String
    let purchaseCents: Int
    let score: Int
    let band: Int?
    let jointBest: Bool
    let yourShareCents: Int
    let reasons: [String]
    var value: ShareCandidate {
        .init(
            purchaseID: purchaseID,
            purchaseCents: purchaseCents,
            score: score,
            band: band,
            jointBest: jointBest,
            yourShareCents: yourShareCents,
            reasons: reasons
        )
    }

    enum CodingKeys: String, CodingKey {
        case score, band, reasons
        case purchaseID = "purchase_id"
        case purchaseCents = "purchase_cents"
        case jointBest = "joint_best"
        case yourShareCents = "your_share_cents"
    }
}

private struct ExpectedCorrection: Decodable {
    let ynabID: String
    let upID: String
    let ynabCents: Int
    let upCents: Int
    let deltaCents: Int
    var value: AmountCorrection {
        .init(ynabID: ynabID, upID: upID, ynabCents: ynabCents, upCents: upCents, deltaCents: deltaCents)
    }

    enum CodingKeys: String, CodingKey {
        case ynabID = "ynab_id"
        case upID = "up_id"
        case ynabCents = "ynab_cents"
        case upCents = "up_cents"
        case deltaCents = "delta_cents"
    }
}

private struct ExpectedAdd: Decodable {
    let upID: String
    let cents: Int
    let date: LocalDate
    let status: String
    let cleared: String
    var value: AddAction { .init(upID: upID, cents: cents, date: date, status: status, cleared: cleared) }

    enum CodingKeys: String, CodingKey {
        case cents, date, status, cleared
        case upID = "up_id"
    }
}

private struct ExpectedQuery: Decodable {
    let ynabID: String
    let cents: Int
    let date: LocalDate
    var value: QueryAction { .init(ynabID: ynabID, cents: cents, date: date) }

    enum CodingKeys: String, CodingKey {
        case cents, date
        case ynabID = "ynab_id"
    }
}
