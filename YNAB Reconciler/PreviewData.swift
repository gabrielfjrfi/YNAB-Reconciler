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
        let decoder = JSONDecoder()
        let up = try! decoder.decode(UpResponse.self, from: fixtureData(named: "edge_up"))
        let ynabResponse = try! decoder.decode(YNABResponse.self, from: fixtureData(named: "edge_ynab"))
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
        model.installFixture(up: up.data, ynab: ynab, categories: categories, payees: payees)
        return model
    }

    static func dryRunFixturePreview() -> ReconcileViewModel {
        let model = fixturePreview()
        model.settings.dryRun = true
        return model
    }

    private static func fixtureData(named name: String) -> Data {
        let url = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "PreviewFixtures")
            ?? Bundle.main.url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
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

private struct PreviewCredentialStore: CredentialStore {
    func save(_ value: String, for credential: Credential) throws {}
    func value(for credential: Credential) throws -> String? { nil }
    func remove(_ credential: Credential) throws {}
}
#endif
