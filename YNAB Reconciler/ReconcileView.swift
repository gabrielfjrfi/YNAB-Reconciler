import SwiftUI
import TransactionKit

struct ReconcileView: View {
    @Bindable var model: ReconcileViewModel
    @State private var presentedSplit: PresentedSplit?

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if let reconciliation = model.reconciliation {
                    Section {
                        BalanceSummaryView(totals: reconciliation.totals)
                    }
                    .listRowBackground(AppTheme.featureCard.opacity(0.98))
                    if let warning = model.balanceWarning {
                        Section {
                            Text(warning)
                                .foregroundStyle(.red)
                                .accessibilityLabel("Balance warning: \(warning)")
                        }
                    }
                    if let message = model.statusMessage {
                        Section {
                            Label(message, systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        SendSelectionSummaryView(
                            selectedCount: model.selectedSendCount
                        )
                    }
                    .listRowBackground(AppTheme.featureCard.opacity(0.98))
                    ForEach(model.actionGroups.filter { !$0.rows.isEmpty }) { group in
                        ActionGroupSection(group: group, model: model) { row in
                            presentedSplit = PresentedSplit(id: row.id)
                        } destination: { row in
                            RowDetailView(model: model, row: row)
                        }
                    }
                    } else {
                        VStack(spacing: 8) {
                            Text("Ready to reconcile")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("Add credentials in Settings, then pull down to refresh.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical)
                    }
                }
            }
            .appListSurface()
            .toolbarBackground(.hidden, for: .tabBar)
            .navigationTitle("Reconcile")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Review") {
                        guard model.canReview else { return }
                        model.prepareReview()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.standout)
                    .foregroundStyle(.white)
                    .disabled(!model.canReview)
                    .allowsHitTesting(model.canReview)
                    .opacity(model.canReview ? 1 : 0.32)
                    .accessibilityHint("Reviews selected transactions before sending")
                }
            }
            .appPullToRefresh(
                isRefreshing: model.isRefreshing,
                lastRefreshDate: model.lastRefreshDate,
                refresh: model.refresh
            )
            .overlay {
                if model.isRefreshing {
                    ZStack {
                        Color.black.opacity(0.75)
                            .ignoresSafeArea()

                        RefreshStatusModal(
                            message: model.refreshProgress?.message ?? "Refreshing…",
                            percentComplete: model.refreshProgress?.percentComplete,
                            cancel: model.cancelRefresh
                        )
                        .padding(.horizontal, 32)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isRefreshing)
            .sheet(item: $presentedSplit) { split in
                SplitPickerView(model: model, depositID: split.id)
            }
            .sheet(item: $model.review) { review in
                ReviewSheet(model: model, review: review)
            }
        }
    }
}

private struct PullToRefreshModifier: ViewModifier {
    private let triggerDistance: CGFloat = 300
    private let indicatorStartDistance: CGFloat = 100

    @GestureState private var pullDistance: CGFloat = 0
    @State private var isAtTop = true

    let isRefreshing: Bool
    let lastRefreshDate: Date?
    let refresh: () async -> Void

    func body(content: Content) -> some View {
        content
            .scrollBounceBehavior(.always)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y <= -geometry.contentInsets.top + 1
            } action: { _, newValue in
                isAtTop = newValue
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .updating($pullDistance) { value, distance, _ in
                        guard isAtTop, !isRefreshing else { return }
                        distance = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        guard isAtTop,
                              !isRefreshing,
                              value.translation.height >= triggerDistance else { return }
                        Task {
                            await refresh()
                        }
                    }
            )
            .overlay(alignment: .top) {
                if !isRefreshing, pullDistance > indicatorStartDistance {
                    PullRefreshIndicator(
                        progress: min(
                            max(
                                (pullDistance - indicatorStartDistance)
                                    / (triggerDistance - indicatorStartDistance),
                                0
                            ),
                            1
                        ),
                        lastRefreshDate: lastRefreshDate
                    )
                    .offset(y: -55)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityScrollAction { edge in
                guard edge == .top, !isRefreshing else { return }
                Task {
                    await refresh()
                }
            }
    }
}

private extension View {
    func appPullToRefresh(
        isRefreshing: Bool,
        lastRefreshDate: Date?,
        refresh: @escaping () async -> Void
    ) -> some View {
        modifier(
            PullToRefreshModifier(
                isRefreshing: isRefreshing,
                lastRefreshDate: lastRefreshDate,
                refresh: refresh
            )
        )
    }
}

private struct PullRefreshIndicator: View {
    let progress: CGFloat
    let lastRefreshDate: Date?

    private var isReady: Bool {
        progress >= 1
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(isReady ? 180 : 0))
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(isReady ? "Release to refresh" : "Pull to refresh")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(lastRefreshText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .opacity(min(1, progress * 2))
        .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
        .animation(.easeOut(duration: 0.16), value: isReady)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isReady ? "Release to refresh" : "Pull to refresh")
        .accessibilityValue(lastRefreshText)
    }

    private var lastRefreshText: String {
        guard let lastRefreshDate else { return "Not refreshed yet" }
        return "Last refreshed \(lastRefreshDate.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct RefreshStatusModal: View {
    let message: String
    let percentComplete: Int?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                if percentComplete == nil {
                    ProgressView()
                        .tint(.white)
                }

                Text(message)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }

            if let percentComplete {
                ProgressView(value: Double(percentComplete), total: 100)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
                    .accessibilityValue("\(percentComplete) percent")
            }

            Button(action: cancel) {
                Text("Cancel refresh")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .foregroundStyle(.white)
            .accessibilityLabel("Cancel refresh")
        }
        .padding(28)
        .frame(maxWidth: 500, minHeight: 180)
        .background(AppTheme.featureCard, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Refresh in progress")
        .accessibilityValue(message)
    }
}

private struct SendSelectionSummaryView: View {
    let selectedCount: Int

    var body: some View {
        Label("\(selectedCount) selected", systemImage: "checkmark.circle")
        .accessibilityElement(children: .combine)
    }
}

private struct PresentedSplit: Identifiable {
    let id: String
}

private struct BalanceSummaryView: View {
    let totals: ReconciliationTotals

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                BalanceValueView(title: "Up", cents: totals.upTotalCents)
                Spacer()
                BalanceValueView(title: "YNAB", cents: totals.ynabTotalCents)
                Spacer()
                BalanceValueView(title: "Difference", cents: totals.gapCents, emphasized: true)
            }
            VStack(alignment: .leading) {
                BalanceValueView(title: "Up", cents: totals.upTotalCents)
                BalanceValueView(title: "YNAB", cents: totals.ynabTotalCents)
                BalanceValueView(title: "Difference", cents: totals.gapCents, emphasized: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BalanceValueView: View {
    let title: LocalizedStringKey
    let cents: Int
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "$\(Money(cents: cents).formatted)")
                .font(emphasized ? .headline : .body)
                .fontWeight(emphasized ? .semibold : .regular)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActionGroupSection<Destination: View>: View {
    let group: ActionGroup
    let model: ReconcileViewModel
    let showSplit: (ActionRow) -> Void
    @ViewBuilder let destination: (ActionRow) -> Destination

    var body: some View {
        Section {
            ForEach(group.rows) { row in
                ActionRowContainer(
                    row: row,
                    isSplit: group.id == .share,
                    model: model,
                    showSplit: { showSplit(row) },
                    destination: { destination(row) }
                )
            }
        } header: {
            ActionGroupHeader(
                title: group.title,
                count: group.rows.count,
                subtotalCents: group.subtotalCents
            )
        } footer: {
            Text(group.explanation)
        }
        .appCardRows()
    }
}

private struct ActionGroupHeader: View {
    let title: String
    let count: Int
    let subtotalCents: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title)
                Text("\(count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "$\(Money(cents: subtotalCents).formatted)")
            }
            VStack(alignment: .leading) {
                Text("\(title) · \(count)")
                Text(verbatim: "$\(Money(cents: subtotalCents).formatted)")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct ActionRowContainer<Destination: View>: View {
    let row: ActionRow
    let isSplit: Bool
    let model: ReconcileViewModel
    let showSplit: () -> Void
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        let locked = model.isLocked(row)
        let categoryRequired = row.isSendable && model.draft(for: row).categoryID == nil
        HStack(alignment: .top, spacing: 12) {
            if row.isSendable && !locked {
                SendSelectionButton(model: model, row: row)
                    .padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 8) {
                if isSplit {
                    Button(action: showSplit) {
                        ActionRowLabel(
                            row: row,
                            status: locked ? .sent : .none
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the ranked split candidates")
                    if categoryRequired && !locked {
                        NavigationLink(destination: destination) {
                            HStack {
                                Spacer()
                                Text("Category required")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .accessibilityLabel("Choose a category for \(row.title)")
                    }
                } else if row.isSendable {
                    NavigationLink(destination: destination) {
                        ActionRowLabel(
                            row: row,
                            status: locked ? .sent : categoryRequired ? .categoryRequired : .none
                        )
                    }
                    .accessibilityHint("Opens payee and category details")
                } else {
                    ActionRowLabel(row: row, status: .none)
                }
            }
        }
    }
}

private struct SendSelectionButton: View {
    let model: ReconcileViewModel
    let row: ActionRow

    var body: some View {
        let blocked = model.draft(for: row).categoryID == nil
        let logUnavailable = model.pushedLogNeedsReset
        let selected = model.selectedRowIDs.contains(row.id)
        Button {
            model.toggleSelection(for: row)
        } label: {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .disabled(blocked || logUnavailable)
        .accessibilityLabel(
            logUnavailable ? "Cannot select; pushed log must be reset" :
                blocked ? "Cannot select; category required" :
                selected ? "Remove from send selection" : "Include in send selection"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ActionRowLabel: View {
    enum Status {
        case none
        case categoryRequired
        case sent
    }

    let row: ActionRow
    let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text(verbatim: "$\(Money(cents: row.balanceEffectCents).formatted)")
                    .font(.body.monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(row.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            HStack(alignment: .lastTextBaseline) {
                Text(row.date.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                switch status {
                case .none:
                    EmptyView()
                case .categoryRequired:
                    Text("Category required")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.orange)
                case .sent:
                    Label("Sent", systemImage: "lock.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Transaction sent")
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.detail), \(row.date.description)")
        .accessibilityValue("$\(Money(cents: row.balanceEffectCents).formatted)")
    }
}

#Preview("Reconcile · Light") {
    ReconcileView(model: .fixturePreview())
        .preferredColorScheme(.light)
}

#Preview("Reconcile · Dark") {
    ReconcileView(model: .fixturePreview())
        .preferredColorScheme(.dark)
}

#Preview("Reconcile · AX5") {
    ReconcileView(model: .fixturePreview())
        .environment(\.dynamicTypeSize, .accessibility5)
}
