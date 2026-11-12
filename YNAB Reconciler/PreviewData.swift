import Foundation
import Networking
import TransactionKit

#if DEBUG
extension ReconcileViewModel {
    static func fixturePreview() -> ReconcileViewModel {
        let defaults = UserDefaults(suiteName: "FixturePreview")!
        defaults.removePersistentDomain(forName: "FixturePreview")
        let model = ReconcileViewModel(
            defaults: defaults,
            credentials: PreviewCredentialStore(),
            pushedLogStorage: MemoryPushedLogStorage(),
            fixtureRefresh: {}
        )
        model.installEdgeFixtures()
        return model
    }

    /// The model behind the `-FixtureData` launch argument. It starts empty, and a refresh
    /// installs the edge fixtures (or fails, when `refreshFails` is set). It never touches
    /// the real defaults, Keychain, pushed log or network.
    static func fixtureLaunch(refreshFails: Bool) -> ReconcileViewModel {
        let suiteName = "FixtureLaunch"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let box = FixtureModelBox()
        let model = ReconcileViewModel(
            defaults: defaults,
            credentials: PreviewCredentialStore(),
            pushedLogStorage: MemoryPushedLogStorage(),
            fixtureRefresh: { [box] in
                guard let model = box.model else { return }
                if refreshFails {
                    model.statusMessage = "Refresh failed. Try again in a moment."
                } else {
                    model.installEdgeFixtures()
                }
            }
        )
        box.model = model
        return model
    }

    /// Loads the bundled edge fixtures (`edge_up`, `edge_ynab`) as if a refresh had fetched them.
    func installEdgeFixtures() {
        let decoder = JSONDecoder()
        let up = try! decoder.decode(UpResponse.self, from: Self.fixtureData(named: "edge_up"))
        let ynabResponse = try! decoder.decode(YNABResponse.self, from: Self.fixtureData(named: "edge_ynab"))
        let ynab = ynabResponse.normalizedTransactions().values

        let categoryValues = Dictionary(
            ynab.compactMap { transaction -> (String, YNABCategory)? in
                guard let id = transaction.categoryID, let name = transaction.categoryName else { return nil }
                return (id, YNABCategory(id: id, name: name))
            },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let categories = [
            YNABCategoryGroup(id: "fixture-categories", name: "Fixture categories", categories: categoryValues)
        ]
        let payees = Set(ynab.map(\.payeeName).filter { !$0.isEmpty })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        installFixture(up: up.data, ynab: ynab, categories: categories, payees: payees)
    }

    static func dryRunFixturePreview() -> ReconcileViewModel {
        let model = fixturePreview()
        model.settings.dryRun = true
        return model
    }

    fileprivate static func fixtureData(named name: String) -> Data {
        let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "PreviewFixtures")
            ?? Bundle.main.url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }
}

extension ActionRow {
    /// The edge fixture only contains a typo correction; these cover the other two causes.
    static func settledDifferentlyPreview() -> ActionRow {
        ActionRow(
            id: "preview-settled",
            kind: .amend,
            title: "Fuel Stop",
            detail: AmendCause.settledDifferently(heldCents: -1_200).shortLabel,
            date: try! LocalDate(isoDate: "2026-09-12"),
            balanceEffectCents: -250,
            isSendable: false,
            ynabEntry: YNABEntry(
                date: try! LocalDate(isoDate: "2026-09-11"),
                payee: "Fuel",
                category: "Transport",
                cents: -1_200
            ),
            amend: AmendDetail(
                cause: .settledDifferently(heldCents: -1_200),
                correctedCents: -1_450,
                differenceCents: -250
            )
        )
    }

    static func repaidHalfPreview() -> ActionRow {
        let repayment = RepaymentInfo(
            date: try! LocalDate(isoDate: "2026-09-15"),
            description: "$partner_handle",
            cents: 3_000
        )
        return ActionRow(
            id: "preview-repaid-half",
            kind: .amend,
            title: "Corner Bistro",
            detail: AmendCause.repaidHalf(repayment).shortLabel,
            date: try! LocalDate(isoDate: "2026-09-13"),
            balanceEffectCents: 3_000,
            isSendable: false,
            ynabEntry: YNABEntry(
                date: try! LocalDate(isoDate: "2026-09-13"),
                payee: "Bistro",
                category: "Eating Out",
                cents: -6_000
            ),
            amend: AmendDetail(
                cause: .repaidHalf(repayment),
                correctedCents: -3_000,
                differenceCents: 3_000
            )
        )
    }
}

extension SendReview {
    static func fixturePreview() -> SendReview {
        let transaction = YNABCreateTransaction(
            accountID: "fixture-account",
            date: try! LocalDate(isoDate: "2026-09-14"),
            amount: -4_150,
            payeeName: "Fixture payee",
            categoryID: "fixture-category",
            cleared: "cleared"
        )
        let request = YNABCreateRequest(transactions: [transaction])
        let prepared = PreparedSend(
            request: request,
            sourceIDs: [["fixture-up-id"]],
            rejections: [],
            skippedLoggedRowIDs: []
        )
        return SendReview(
            id: UUID(),
            rows: [
                ReviewRow(
                    id: "fixture-up-id",
                    date: transaction.date,
                    payee: transaction.payeeName,
                    category: "Fixture category",
                    cents: -415
                )
            ],
            totalCents: -415,
            outstandingAfterCents: -1_200,
            payloadJSON: String(data: try! request.encoded(), encoding: .utf8)!,
            prepared: prepared
        )
    }
}

/// Lets the fixture refresh closure reach the model it belongs to.
final class FixtureModelBox {
    weak var model: ReconcileViewModel?
}

private struct PreviewCredentialStore: CredentialStore {
    func save(_ value: String, for credential: Credential) throws {}
    func value(for credential: Credential) throws -> String? { nil }
    func remove(_ credential: Credential) throws {}
}
#endif
