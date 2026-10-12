import Foundation
import LocalAuthentication
import Networking
import Observation
import TransactionKit

struct ReconcileSettings: Equatable {
    var startDate: Date
    var ynabPlanID: String
    var ynabAccountID: String
    var upAccountID: String
    var partnerHandles: String
    var tolerance: Int
    var reimbursementWindow: Int
    var settleWindow: Int
    var amendToleranceCents: Int
    var amendDays: Int
    var scoreFloor: Int
    var shortlistSize: Int
    var heldStatus: String
    var dryRun: Bool

    static func defaults(calendar: Calendar = .current) -> ReconcileSettings {
        let now = Date()
        let components = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: components) ?? now
        return ReconcileSettings(
            startDate: monthStart,
            ynabPlanID: "",
            ynabAccountID: "",
            upAccountID: "",
            partnerHandles: "",
            tolerance: 7,
            reimbursementWindow: 14,
            settleWindow: 30,
            amendToleranceCents: 100,
            amendDays: 3,
            scoreFloor: 25,
            shortlistSize: 5,
            heldStatus: "cleared",
            dryRun: false
        )
    }

    var partners: [String] {
        partnerHandles
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct TransactionDraft: Equatable {
    var payee: String
    var categoryID: String?
    var categoryName: String?
}

struct ActionRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case add
        case share
        case amend
        case query
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let date: LocalDate
    let balanceEffectCents: Int
    let isSendable: Bool
}

struct ActionGroup: Identifiable, Equatable {
    enum ID: String, CaseIterable {
        case add
        case share
        case amend
        case query
        case sent
    }

    let id: ID
    let title: String
    let explanation: String
    let rows: [ActionRow]
    let subtotalCents: Int
}

struct ReviewRow: Identifiable, Equatable {
    let id: String
    let date: LocalDate
    let payee: String
    let category: String
    let cents: Int
}

struct SendReview: Identifiable, Equatable {
    let id: UUID
    let rows: [ReviewRow]
    let totalCents: Int
    let outstandingAfterCents: Int
    let payloadJSON: String
    let prepared: PreparedSend
}

enum RefreshProgress: Equatable {
    case connecting
    case fetchingUp(pages: Int, transactions: Int)
    case reconciling(up: Int, ynab: Int)
    case comparing(ReconciliationProgress)
    case cancelling

    var message: String {
        switch self {
        case .connecting:
            return "Connecting to Up and YNAB…"
        case let .fetchingUp(pages, transactions):
            return "Fetching Up — \(transactions) transactions across \(pages) pages"
        case let .reconciling(up, ynab):
            return "Preparing to compare \(up) Up and \(ynab) YNAB transactions…"
        case let .comparing(progress):
            let units = progress.totalUnits > 0
                ? " — \(progress.completedUnits) of \(progress.totalUnits)"
                : ""
            return "\(progress.pass.rawValue) — \(progress.percentComplete)%\(units)"
        case .cancelling:
            return "Cancelling refresh…"
        }
    }

    var percentComplete: Int? {
        guard case let .comparing(progress) = self else { return nil }
        return progress.percentComplete
    }
}

@MainActor
@Observable
final class ReconcileViewModel {
    private struct RefreshOutput: Sendable {
        let up: [UpTransaction]
        let ynab: [YNABTransaction]
        let categories: [YNABCategoryGroup]
        let payees: [String]
        let reconciliation: Reconciliation
    }

    private enum RefreshFailure: Error {
        case overallTimeout
    }

    private enum DefaultsKey {
        static let startDate = "reconcileStartDate"
        static let partners = "splitPartnerHandles"
        static let tolerance = "reconcileTolerance"
        static let reimbursementWindow = "reimbursementWindow"
        static let settleWindow = "settleWindow"
        static let amendTolerance = "amendToleranceCents"
        static let amendDays = "amendDays"
        static let scoreFloor = "scoreFloor"
        static let shortlistSize = "shortlistSize"
        static let heldStatus = "heldStatus"
        static let dryRun = "dryRun"
        static let lastRefresh = "lastRefresh"
    }

    var reconciliation: Reconciliation?
    var categories: [YNABCategoryGroup] = []
    var payees: [String] = []
    var settings: ReconcileSettings
    var upToken = ""
    var ynabToken = ""
    var isRefreshing = false
    var refreshProgress: RefreshProgress?
    var lastRefreshDate: Date?
    var statusMessage: String?
    var balanceWarning: String?
    var drafts: [String: TransactionDraft] = [:]
    var selectedRowIDs: Set<String> = []
    var pushedLog: [String: Date] = [:]
    var pushedLogNeedsReset = false
    var review: SendReview?
    var isSending = false
    var sendResultMessage: String?
    var lastRefreshHadNoDiscrepancies = false

    private var upTransactions: [UpTransaction] = []
    private var ynabTransactions: [YNABTransaction] = []
    private var splitDecisions: [String: SplitDecision] = [:]
    private let defaults: UserDefaults
    private let credentials: any CredentialStore
    private let accountSettings: AccountSettingsStore
    private let fixtureRefresh: (@MainActor () -> Void)?
    private let pushedLogStorage: any PushedLogStorage
    @ObservationIgnored private var refreshTask: Task<RefreshOutput, Error>?
    @ObservationIgnored private var refreshID: UUID?

    init(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStore = KeychainCredentialStore(service: "YNABReconcile"),
        pushedLogStorage: (any PushedLogStorage)? = nil,
        fixtureRefresh: (@MainActor () -> Void)? = nil
    ) {
        self.defaults = defaults
        self.credentials = credentials
        accountSettings = AccountSettingsStore(defaults: defaults)
        self.fixtureRefresh = fixtureRefresh
        self.pushedLogStorage = pushedLogStorage ?? ((try? DiskPushedLogStorage()) ?? MemoryPushedLogStorage())
        settings = Self.loadSettings(defaults: defaults, accountSettings: accountSettings)
        lastRefreshDate = defaults.object(forKey: DefaultsKey.lastRefresh) as? Date
        loadTokens()
        loadPushedLog()
    }

    var actionGroups: [ActionGroup] {
        guard let reconciliation else { return [] }
        let groups = [
            ActionGroup(
                id: .add,
                title: "Enter in YNAB",
                explanation: "In Up, with nothing in YNAB behind it.",
                rows: reconciliation.adds.compactMap(addRow),
                subtotalCents: reconciliation.totals.addTotalCents
            ),
            ActionGroup(
                id: .share,
                title: "Enter your half",
                explanation: "Shared costs already settled up.",
                rows: reconciliation.shareBlocks.compactMap(shareRow),
                subtotalCents: reconciliation.totals.shareTotalCents
                    + reconciliation.totals.unassignedRepaymentTotalCents
            ),
            ActionGroup(
                id: .amend,
                title: "Correct the amount",
                explanation: "Likely amount entry mistakes to fix in YNAB.",
                rows: reconciliation.amends.compactMap(amendRow),
                subtotalCents: reconciliation.totals.amendTotalCents
            ),
            ActionGroup(
                id: .query,
                title: "Check these yourself",
                explanation: "YNAB entries with no counterpart in Up.",
                rows: reconciliation.queries.compactMap(queryRow),
                subtotalCents: reconciliation.totals.queryTotalCents
            )
        ]
        let sentRows = groups.flatMap(\.rows).filter(isLocked)
        let pendingGroups = groups.map { group in
            let rows = group.rows.filter { !isLocked($0) }
            return ActionGroup(
                id: group.id,
                title: group.title,
                explanation: group.explanation,
                rows: rows,
                subtotalCents: rows.reduce(0) { $0 + $1.balanceEffectCents }
            )
        }

        guard !sentRows.isEmpty else { return pendingGroups }
        return pendingGroups + [
            ActionGroup(
                id: .sent,
                title: "Sent",
                explanation: "Transactions already sent to YNAB.",
                rows: sentRows,
                subtotalCents: sentRows.reduce(0) { $0 + $1.balanceEffectCents }
            )
        ]
    }

    var selectedSendCount: Int {
        selectedRowIDs.count
    }

    var canReview: Bool {
        selectedSendCount > 0 && balanceWarning == nil
    }

    var hasNoDiscrepancies: Bool {
        guard let reconciliation,
              reconciliation.totals.gapCents == 0,
              balanceWarning == nil else { return false }
        return actionGroups
            .filter { $0.id != .sent }
            .allSatisfy(\.rows.isEmpty)
    }

    func refresh() async {
        if let fixtureRefresh {
            fixtureRefresh()
            return
        }
        guard !upToken.isEmpty, !ynabToken.isEmpty else {
            statusMessage = "Add both API tokens in Settings before refreshing."
            return
        }
        guard !settings.ynabPlanID.isEmpty, !settings.ynabAccountID.isEmpty else {
            statusMessage = "Choose a YNAB plan and account in Settings before refreshing."
            return
        }
        isRefreshing = true
        statusMessage = nil
        refreshProgress = .connecting
        let operationID = UUID()
        refreshID = operationID
        defer {
            if refreshID == operationID {
                refreshTask = nil
                refreshID = nil
                refreshProgress = nil
                isRefreshing = false
            }
        }

        let upToken = self.upToken
        let ynabToken = self.ynabToken
        let planID = settings.ynabPlanID
        let accountID = settings.ynabAccountID
        let upAccountID = settings.upAccountID.isEmpty ? nil : settings.upAccountID
        let since = localDate(from: settings.startDate)
        let timeZone = TimeZone.current
        let parameters = reconciliationParameters
        let progress: @Sendable (RefreshProgress) async -> Void = { [weak self] value in
            await self?.setRefreshProgress(value, operationID: operationID)
        }
        let task = Task.detached(priority: .userInitiated) {
            try await Self.performRefresh(
                upToken: upToken,
                ynabToken: ynabToken,
                planID: planID,
                accountID: accountID,
                upAccountID: upAccountID,
                since: since,
                timeZone: timeZone,
                parameters: parameters,
                progress: progress
            )
        }
        refreshTask = task
        do {
            let output = try await task.value
            guard refreshID == operationID else { return }
            upTransactions = output.up
            ynabTransactions = output.ynab
            categories = output.categories
            payees = output.payees
            installReconciliation(output.reconciliation)
            lastRefreshHadNoDiscrepancies = hasNoDiscrepancies
            lastRefreshDate = Date()
            defaults.set(lastRefreshDate, forKey: DefaultsKey.lastRefresh)
            statusMessage = nil
        } catch is CancellationError {
            statusMessage = nil
        } catch RefreshFailure.overallTimeout {
            statusMessage = "Refresh stopped after 3 minutes. Try a more recent start date or try again."
        } catch NetworkError.timedOut {
            statusMessage = "A request timed out after 30 seconds. Check your connection and try again."
        } catch NetworkError.paginationLoop {
            statusMessage = "Up returned a repeated pagination link. Refresh stopped to prevent an infinite loop."
        } catch NetworkError.invalidToken {
            statusMessage = "An API token is invalid or has been revoked. Check Settings."
        } catch NetworkError.wrongPlanOrAccount {
            statusMessage = "The YNAB plan or account could not be found. Check Settings."
        } catch NetworkError.rateLimited {
            statusMessage = "The service is rate limited. Try refreshing later."
        } catch {
            statusMessage = "Refresh failed. Try again in a moment."
        }
    }

    func cancelRefresh() {
        guard isRefreshing else { return }
        refreshProgress = .cancelling
        refreshTask?.cancel()
    }

    @discardableResult
    func saveSettings() -> Bool {
        do {
            if upToken.isEmpty {
                try credentials.remove(.upToken)
            } else {
                try credentials.save(upToken, for: .upToken)
            }
            if ynabToken.isEmpty {
                try credentials.remove(.ynabToken)
            } else {
                try credentials.save(ynabToken, for: .ynabToken)
            }
            accountSettings.ynabPlanID = settings.ynabPlanID.nilIfEmpty
            accountSettings.ynabAccountID = settings.ynabAccountID.nilIfEmpty
            accountSettings.upAccountID = settings.upAccountID.nilIfEmpty
            persistParameters()
            statusMessage = nil
            if !upTransactions.isEmpty || !ynabTransactions.isEmpty {
                reconcile()
            }
            return true
        } catch {
            statusMessage = "Credentials could not be saved securely."
            return false
        }
    }

    func selectCandidate(depositID: String, purchaseID: String) {
        splitDecisions[depositID] = .purchase(id: purchaseID)
        reconcile()
    }

    func rejectSplit(depositID: String) {
        splitDecisions[depositID] = .notASplit
        reconcile()
    }

    func resetSplitToAutomatic(depositID: String) {
        splitDecisions[depositID] = nil
        reconcile()
    }

    func hasManualSplitSelection(depositID: String) -> Bool {
        guard case .purchase = splitDecisions[depositID] else { return false }
        return true
    }

    func splitBlock(depositID: String) -> ShareBlock? {
        reconciliation?.shareBlocks.first { $0.depositID == depositID }
    }

    func transaction(upID: String) -> UpTransaction? {
        upTransactions.first { $0.id == upID }
    }

    func draft(for row: ActionRow) -> TransactionDraft {
        if let draft = drafts[row.id] { return draft }
        return TransactionDraft(payee: row.title, categoryID: nil, categoryName: nil)
    }

    func setPayee(_ payee: String, for rowID: String) {
        var draft = drafts[rowID] ?? TransactionDraft(payee: payee, categoryID: nil, categoryName: nil)
        draft.payee = payee
        drafts[rowID] = draft
    }

    func setCategory(_ category: YNABCategory?, for row: ActionRow) {
        var draft = drafts[row.id] ?? TransactionDraft(payee: row.title, categoryID: nil, categoryName: nil)
        let wasCategoryRequired = draft.categoryID == nil
        draft.categoryID = category?.id
        draft.categoryName = category?.name
        drafts[row.id] = draft

        if category == nil {
            selectedRowIDs.remove(row.id)
        } else if wasCategoryRequired,
                  balanceWarning == nil,
                  !pushedLogNeedsReset,
                  row.isSendable,
                  !isLocked(row) {
            selectedRowIDs.insert(row.id)
        }
    }

    func selectedCategory(for row: ActionRow) -> YNABCategory? {
        guard let id = drafts[row.id]?.categoryID else { return nil }
        return categories.lazy.flatMap(\.categories).first { $0.id == id }
    }

    func isLocked(_ row: ActionRow) -> Bool {
        sourceIDs(for: row).contains { pushedLog[$0] != nil }
    }

    func toggleSelection(for row: ActionRow) {
        guard balanceWarning == nil,
              !pushedLogNeedsReset,
              row.isSendable,
              !isLocked(row),
              draft(for: row).categoryID != nil else { return }
        if selectedRowIDs.contains(row.id) {
            selectedRowIDs.remove(row.id)
        } else {
            selectedRowIDs.insert(row.id)
        }
    }

    func prepareReview() {
        guard let reconciliation else { return }
        guard balanceWarning == nil else {
            statusMessage = "Sending is blocked until the reconciliation balance identity is restored."
            return
        }
        guard !pushedLogNeedsReset else {
            statusMessage = "Clear the unreadable pushed log in Settings before sending."
            return
        }
        guard !settings.ynabPlanID.isEmpty, !settings.ynabAccountID.isEmpty else {
            statusMessage = "Add YNAB plan and account IDs in Settings before reviewing."
            return
        }
        let selections = sendableRows
            .filter { selectedRowIDs.contains($0.id) }
            .map {
                let draft = draft(for: $0)
                return SendSelection(rowID: $0.id, categoryID: draft.categoryID, payee: draft.payee)
            }
        let prepared = YNABPayloadBuilder().build(
            reconciliation: reconciliation,
            upTransactions: upTransactions,
            selections: selections,
            accountID: settings.ynabAccountID,
            heldStatus: settings.heldStatus,
            pushedIDs: Set(pushedLog.keys)
        )
        guard prepared.rejections.isEmpty,
              prepared.skippedLoggedRowIDs.isEmpty,
              !prepared.request.transactions.isEmpty else {
            statusMessage = "The selected rows are no longer ready to send. Review their payees and categories."
            selectedRowIDs.subtract(prepared.skippedLoggedRowIDs)
            return
        }
        do {
            let payloadData = try prepared.request.encoded()
            guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
                statusMessage = "The YNAB payload could not be displayed."
                return
            }
            let rows = zip(prepared.request.transactions, prepared.sourceIDs).map { transaction, ids in
                ReviewRow(
                    id: ids.joined(separator: ":"),
                    date: transaction.date,
                    payee: transaction.payeeName,
                    category: categoryName(for: transaction.categoryID),
                    cents: transaction.amount / 10
                )
            }
            let total = rows.reduce(0) { $0 + $1.cents }
            let alreadyPushed = sendableRows
                .filter(isLocked)
                .reduce(0) { $0 + $1.balanceEffectCents }
            review = SendReview(
                id: UUID(),
                rows: rows,
                totalCents: total,
                outstandingAfterCents: reconciliation.totals.gapCents - alreadyPushed - total,
                payloadJSON: payloadJSON,
                prepared: prepared
            )
            sendResultMessage = nil
        } catch {
            statusMessage = "The YNAB payload could not be encoded."
        }
    }

    func confirmSend() async {
        guard let review else { return }
        if settings.dryRun {
            sendResultMessage = "Dry run complete. Nothing was sent or added to the pushed log."
            return
        }
        guard !ynabToken.isEmpty else {
            sendResultMessage = "Add a YNAB API token in Settings before sending."
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            let context = LAContext()
            context.localizedCancelTitle = String(localized: "Cancel")
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Confirm sending these transactions to YNAB")
            )
            guard authenticated else {
                sendResultMessage = "Authentication failed. Nothing was sent."
                return
            }
            let client = YNABClient(token: ynabToken, httpClient: RetryingHTTPClient())
            let createdIDs = try await client.createTransactions(
                planID: settings.ynabPlanID,
                request: review.prepared.request
            )
            guard createdIDs.count == review.prepared.request.transactions.count else {
                sendResultMessage = "YNAB returned an unexpected result. Nothing was added to the pushed log."
                return
            }
            let timestamp = Date()
            let sentSourceIDs = review.prepared.sourceIDs.flatMap { $0 }
            for id in sentSourceIDs {
                pushedLog[id] = timestamp
            }
            do {
                try pushedLogStorage.save(pushedLog)
                selectedRowIDs.removeAll()
                self.review = nil
                statusMessage = nil
            } catch {
                sendResultMessage = "YNAB accepted the transactions, but duplicate protection could not be saved. Do not send them again."
            }
        } catch let error as LAError where error.code == .userCancel || error.code == .systemCancel || error.code == .appCancel {
            sendResultMessage = "Authentication was cancelled. Nothing was sent."
        } catch is LAError {
            sendResultMessage = "Authentication failed. Nothing was sent."
        } catch NetworkError.invalidToken {
            sendResultMessage = "The YNAB token is invalid or has been revoked."
        } catch NetworkError.wrongPlanOrAccount {
            sendResultMessage = "The YNAB plan or account could not be found."
        } catch {
            sendResultMessage = "Nothing was sent. Try again in a moment."
        }
    }

    func clearPushedLog() {
        do {
            pushedLog = [:]
            try pushedLogStorage.save([:])
            pushedLogNeedsReset = false
            statusMessage = "Pushed log cleared."
        } catch {
            statusMessage = "The pushed log could not be cleared."
        }
    }

    func installFixture(
        up: [UpTransaction],
        ynab: [YNABTransaction],
        categories: [YNABCategoryGroup],
        payees: [String]
    ) {
        upTransactions = up
        ynabTransactions = ynab
        self.categories = categories
        self.payees = payees
        settings.ynabPlanID = "fixture-plan"
        settings.ynabAccountID = "fixture-account"
        settings.partnerHandles = "$partner_handle"
        reconcile()
    }

    private var reconciliationParameters: ReconciliationParameters {
        ReconciliationParameters(
            tolerance: settings.tolerance,
            reimbursementWindow: settings.reimbursementWindow,
            settleWindow: settings.settleWindow,
            amendToleranceCents: settings.amendToleranceCents,
            amendDays: settings.amendDays,
            scoreFloor: settings.scoreFloor,
            shortlistSize: settings.shortlistSize,
            partners: settings.partners,
            heldStatus: settings.heldStatus,
            splitDecisions: splitDecisions
        )
    }

    private func setRefreshProgress(_ progress: RefreshProgress, operationID: UUID) {
        guard refreshID == operationID else { return }
        refreshProgress = progress
    }

    private static func performRefresh(
        upToken: String,
        ynabToken: String,
        planID: String,
        accountID: String,
        upAccountID: String?,
        since: LocalDate,
        timeZone: TimeZone,
        parameters: ReconciliationParameters,
        progress: @escaping @Sendable (RefreshProgress) async -> Void
    ) async throws -> RefreshOutput {
        try await withOverallTimeout {
            let cache = try DiskResponseCache()
            let httpClient = RetryingHTTPClient()
            let upClient = UpClient(token: upToken, httpClient: httpClient, cache: cache)
            let ynabClient = YNABClient(token: ynabToken, httpClient: httpClient, cache: cache)

            async let fetchedUp = upClient.fetchTransactions(
                since: since,
                timeZone: timeZone,
                accountID: upAccountID
            ) { upProgress in
                await progress(.fetchingUp(
                    pages: upProgress.pagesFetched,
                    transactions: upProgress.transactionsFetched
                ))
            }
            async let fetchedYNAB = ynabClient.fetchTransactions(
                planID: planID,
                accountID: accountID,
                since: since
            )
            async let fetchedCategories = ynabClient.fetchCategories(planID: planID)
            async let fetchedPayees = ynabClient.fetchPayees(planID: planID)

            let (up, ynab, categoryGroups, payeeNames) = try await (
                fetchedUp,
                fetchedYNAB,
                fetchedCategories,
                fetchedPayees
            )
            try Task.checkCancellation()
            await progress(.reconciling(up: up.count, ynab: ynab.count))
            let reconciliation = try Reconciler().reconcileCancellable(
                up: up,
                ynab: ynab,
                parameters: parameters
            ) { comparisonProgress in
                Task {
                    await progress(.comparing(comparisonProgress))
                }
            }
            try Task.checkCancellation()
            return RefreshOutput(
                up: up,
                ynab: ynab,
                categories: categoryGroups,
                payees: payeeNames,
                reconciliation: reconciliation
            )
        }
    }

    private static func withOverallTimeout<T: Sendable>(
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(180))
                throw RefreshFailure.overallTimeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            return result
        }
    }

    private func reconcile() {
        let result = Reconciler().reconcile(
            up: upTransactions,
            ynab: ynabTransactions,
            parameters: reconciliationParameters
        )
        installReconciliation(result)
    }

    private func installReconciliation(_ result: Reconciliation) {
        reconciliation = result
        balanceWarning = result.totals.identityHolds
            ? nil
            : "The action totals do not equal the Up–YNAB difference. Do not send anything."
        if result.totals.identityHolds {
            selectedRowIDs.formIntersection(Set(sendableRows.filter { !isLocked($0) }.map(\.id)))
        } else {
            selectedRowIDs.removeAll()
        }
    }

    private func addRow(_ action: AddAction) -> ActionRow? {
        guard let transaction = transaction(upID: action.upID) else { return nil }
        return ActionRow(
            id: action.upID,
            kind: .add,
            title: transaction.description,
            detail: action.status == "HELD" ? "Pending in Up" : "Ready to enter",
            date: action.date,
            balanceEffectCents: action.cents,
            isSendable: true
        )
    }

    private func shareRow(_ block: ShareBlock) -> ActionRow? {
        guard let deposit = transaction(upID: block.depositID) else { return nil }
        let chosen = block.chosenPurchaseID.flatMap(transaction)
        let title = chosen?.description ?? deposit.description
        let detail: String
        if chosen != nil {
            detail = "Paired with repayment from \(deposit.description)"
        } else {
            detail = "Needs a purchase selection"
        }
        return ActionRow(
            id: block.depositID,
            kind: .share,
            title: title,
            detail: detail,
            date: chosen?.date ?? deposit.date,
            balanceEffectCents: block.yourShareCents ?? block.depositCents,
            isSendable: chosen != nil
        )
    }

    private func amendRow(_ correction: AmountCorrection) -> ActionRow? {
        guard let transaction = transaction(upID: correction.upID) else { return nil }
        return ActionRow(
            id: correction.upID,
            kind: .amend,
            title: transaction.description,
            detail: "YNAB differs by \(Money(cents: correction.deltaCents).formatted)",
            date: transaction.date,
            balanceEffectCents: correction.deltaCents,
            isSendable: false
        )
    }

    private func queryRow(_ query: QueryAction) -> ActionRow? {
        guard let transaction = ynabTransactions.first(where: { $0.id == query.ynabID }) else { return nil }
        return ActionRow(
            id: query.ynabID,
            kind: .query,
            title: transaction.payeeName,
            detail: "Check or remove this YNAB entry",
            date: query.date,
            balanceEffectCents: -query.cents,
            isSendable: false
        )
    }

    private func loadTokens() {
        do {
            upToken = try credentials.value(for: .upToken) ?? ""
            ynabToken = try credentials.value(for: .ynabToken) ?? ""
        } catch {
            statusMessage = "Stored credentials could not be read."
        }
    }

    private func loadPushedLog() {
        do {
            pushedLog = try pushedLogStorage.load()
            pushedLogNeedsReset = false
        } catch {
            pushedLog = [:]
            pushedLogNeedsReset = true
            statusMessage = "The pushed log could not be read. Sending is disabled until it is cleared."
        }
    }

    private func persistParameters() {
        defaults.set(settings.startDate, forKey: DefaultsKey.startDate)
        defaults.set(settings.partnerHandles, forKey: DefaultsKey.partners)
        defaults.set(settings.tolerance, forKey: DefaultsKey.tolerance)
        defaults.set(settings.reimbursementWindow, forKey: DefaultsKey.reimbursementWindow)
        defaults.set(settings.settleWindow, forKey: DefaultsKey.settleWindow)
        defaults.set(settings.amendToleranceCents, forKey: DefaultsKey.amendTolerance)
        defaults.set(settings.amendDays, forKey: DefaultsKey.amendDays)
        defaults.set(settings.scoreFloor, forKey: DefaultsKey.scoreFloor)
        defaults.set(settings.shortlistSize, forKey: DefaultsKey.shortlistSize)
        defaults.set(settings.heldStatus, forKey: DefaultsKey.heldStatus)
        defaults.set(settings.dryRun, forKey: DefaultsKey.dryRun)
    }

    private static func loadSettings(
        defaults: UserDefaults,
        accountSettings: AccountSettingsStore
    ) -> ReconcileSettings {
        var settings = ReconcileSettings.defaults()
        settings.startDate = defaults.object(forKey: DefaultsKey.startDate) as? Date ?? settings.startDate
        settings.ynabPlanID = accountSettings.ynabPlanID ?? ""
        settings.ynabAccountID = accountSettings.ynabAccountID ?? ""
        settings.upAccountID = accountSettings.upAccountID ?? ""
        settings.partnerHandles = defaults.string(forKey: DefaultsKey.partners) ?? ""
        settings.tolerance = positive(defaults.integer(forKey: DefaultsKey.tolerance), fallback: 7)
        settings.reimbursementWindow = positive(defaults.integer(forKey: DefaultsKey.reimbursementWindow), fallback: 14)
        settings.settleWindow = positive(defaults.integer(forKey: DefaultsKey.settleWindow), fallback: 30)
        settings.amendToleranceCents = positive(defaults.integer(forKey: DefaultsKey.amendTolerance), fallback: 100)
        settings.amendDays = positive(defaults.integer(forKey: DefaultsKey.amendDays), fallback: 3)
        settings.scoreFloor = positive(defaults.integer(forKey: DefaultsKey.scoreFloor), fallback: 25)
        settings.shortlistSize = positive(defaults.integer(forKey: DefaultsKey.shortlistSize), fallback: 5)
        settings.heldStatus = defaults.string(forKey: DefaultsKey.heldStatus) ?? "cleared"
        settings.dryRun = defaults.bool(forKey: DefaultsKey.dryRun)
        return settings
    }

    private static func positive(_ value: Int, fallback: Int) -> Int {
        value > 0 ? value : fallback
    }

    private func localDate(from date: Date) -> LocalDate {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return try! LocalDate(
            year: components.year!,
            month: components.month!,
            day: components.day!
        )
    }

    private var sendableRows: [ActionRow] {
        actionGroups.flatMap(\.rows).filter(\.isSendable)
    }

    private func sourceIDs(for row: ActionRow) -> [String] {
        guard row.kind == .share,
              let block = reconciliation?.shareBlocks.first(where: { $0.depositID == row.id }),
              let purchaseID = block.chosenPurchaseID else {
            return [row.id]
        }
        return [purchaseID, block.depositID]
    }

    private func categoryName(for id: String) -> String {
        categories.lazy.flatMap(\.categories).first(where: { $0.id == id })?.name ?? id
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
