import Foundation
import Networking
import Testing
import TransactionKit
@testable import YNAB_Reconciler

/// Start-date and caption rules from plans 001–001c, plus the fixture balance identity.
@MainActor
struct StartDateTests {
    /// In-memory stand-in for the Keychain.
    private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
        private var values: [Credential: String] = [:]

        func save(_ value: String, for credential: Credential) throws {
            values[credential] = value
        }

        func value(for credential: Credential) throws -> String? {
            values[credential]
        }

        func remove(_ credential: Credential) throws {
            values[credential] = nil
        }
    }

    private let suiteName = "YNABReconcilerTests-\(UUID().uuidString)"

    private var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    private func makeModel() -> ReconcileViewModel {
        ReconcileViewModel(
            defaults: defaults,
            credentials: MemoryCredentialStore(),
            pushedLogStorage: MemoryPushedLogStorage()
        )
    }

    /// Same format as the caption, so the tests don't depend on the simulator's locale.
    private func formatted(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    private var monthStart: Date {
        ReconcileSettings.defaults().startDate
    }

    private var otherDate: Date {
        Calendar.current.date(byAdding: .day, value: 10, to: monthStart)!
    }

    // 1
    @Test func newModelStartsOnFirstOfMonth() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()
        let components = Calendar.current.dateComponents([.year, .month, .day], from: model.settings.startDate)
        let now = Calendar.current.dateComponents([.year, .month], from: Date())
        #expect(components.day == 1)
        #expect(components.year == now.year)
        #expect(components.month == now.month)
        #expect(!model.isStartDateCustom)
    }

    // 2
    @Test func legacyStoredStartDateIsRemovedAndIgnored() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = Calendar.current.date(byAdding: .month, value: -2, to: monthStart)!
        defaults.set(legacy, forKey: "reconcileStartDate")

        let model = makeModel()

        #expect(defaults.object(forKey: "reconcileStartDate") == nil)
        #expect(Calendar.current.isDate(model.settings.startDate, inSameDayAs: monthStart))
        #expect(!model.isStartDateCustom)
    }

    // 3
    @Test func changingTheDateMakesItCustomUntilReset() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()

        model.settings.startDate = otherDate
        #expect(model.isStartDateCustom)

        model.useAutomaticStartDate()
        #expect(!model.isStartDateCustom)
        #expect(Calendar.current.isDate(model.settings.startDate, inSameDayAs: monthStart))
    }

    // 4
    @Test func savingSettingsDoesNotPersistTheStartDate() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()
        model.settings.startDate = otherDate
        #expect(model.saveSettings())

        let relaunched = makeModel()

        #expect(Calendar.current.isDate(relaunched.settings.startDate, inSameDayAs: monthStart))
        #expect(!relaunched.isStartDateCustom)
    }

    // 5
    @Test func emptyStateCaptionSaysReconciling() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()
        #expect(model.reconciliation == nil)
        #expect(model.startDateCaption == "Reconciling from \(formatted(monthStart))")
    }

    // 6
    @Test func captionSaysReconciledOnceResultsAreInstalled() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()
        model.installEdgeFixtures()
        #expect(model.reconciliation != nil)
        #expect(model.startDateCaption == "Reconciled from \(formatted(monthStart))")
    }

    // 7
    @Test func captionKeepsTheOldDateWhenSettingsChange() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()
        model.installEdgeFixtures()

        model.settings.startDate = otherDate

        #expect(model.isStartDateCustom)
        #expect(model.startDateCaption == "Reconciled from \(formatted(monthStart))")
    }

    // 8
    @Test func failedRefreshLeavesCaptionAndReconciledDateAlone() async {
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Empty state: no tokens, so the refresh stops before fetching.
        let empty = makeModel()
        empty.settings.startDate = otherDate
        let emptyCaption = empty.startDateCaption
        await empty.refresh()
        #expect(empty.reconciledStartDate == nil)
        #expect(empty.reconciliation == nil)
        #expect(empty.startDateCaption == emptyCaption)
        #expect(empty.statusMessage != nil)

        // Results already on screen: the caption keeps the date they came from.
        let loaded = makeModel()
        loaded.installEdgeFixtures()
        let reconciledDate = loaded.reconciledStartDate
        let loadedCaption = loaded.startDateCaption
        loaded.settings.startDate = otherDate
        await loaded.refresh()
        #expect(loaded.reconciledStartDate == reconciledDate)
        #expect(loaded.startDateCaption == loadedCaption)
        #expect(loaded.startDateCaption == "Reconciled from \(formatted(monthStart))")
        #expect(loaded.statusMessage != nil)
    }

    // 9
    @Test func edgeFixturesSatisfyTheBalanceIdentity() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeModel()
        model.installEdgeFixtures()
        #expect(model.reconciliation?.totals.identityHolds == true)
        #expect(model.balanceWarning == nil)
    }
}
