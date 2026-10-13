import SwiftUI
import TransactionKit

struct ReconcileView: View {
    @Bindable var model: ReconcileViewModel
    @State private var celebrationID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if let reconciliation = model.reconciliation {
                    Section {
                        BalanceSummaryView(
                            totals: reconciliation.totals,
                            accountBalances: model.accountBalances
                        )
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
                    if model.hasPendingTransactions {
                        Section {
                            SendSelectionSummaryView(
                                selectedCount: model.selectedSendCount
                            )
                        }
                        .listRowBackground(AppTheme.featureCard.opacity(0.98))
                    }
                    if model.lastRefreshHadNoDiscrepancies {
                        Text("No gap between UP and YNAB.")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(model.actionGroups.filter { !$0.rows.isEmpty }) { group in
                        if group.id == .sent {
                            SentHistorySection(group: group)
                        } else {
                            ActionGroupSection(group: group, model: model) { row in
                                RowDetailView(model: model, row: row)
                            }
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
                ZStack {
                    if let celebrationID {
                        ReconciliationCelebrationView {
                            self.celebrationID = nil
                        }
                        .id(celebrationID)
                        .transition(.opacity)
                    }

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
            }
            .animation(.easeInOut(duration: 0.2), value: model.isRefreshing)
            .onChange(of: model.lastRefreshDate) { _, newValue in
                guard newValue != nil, model.hasNoDiscrepancies else { return }
                celebrationID = UUID()
            }
            .sheet(item: $model.review) { review in
                ReviewSheet(model: model, review: review)
            }
        }
    }
}

private struct ReconciliationCelebrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onFinished: () -> Void
    private let startedAt = Date()

    var body: some View {
        Group {
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let elapsed = timeline.date.timeIntervalSince(startedAt)
                        drawConfetti(in: &context, size: size, elapsed: elapsed)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task {
            try? await Task.sleep(for: .seconds(reduceMotion ? 0.1 : 4.5))
            onFinished()
        }
    }

    private func drawConfetti(
        in context: inout GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval
    ) {
        for particle in ConfettiParticle.all {
            let age = elapsed - particle.delay
            guard age >= 0, age <= 4.5 else { continue }

            let x = size.width / 2
                + particle.horizontalVelocity * age
                + sin(age * 4 + particle.phase) * 12
            let y = size.height + 12
                - particle.upwardVelocity * age
                + 0.5 * 420 * age * age
            let opacity = age > 3.8 ? max(0, (4.5 - age) / 0.7) : 1
            let rect = CGRect(
                x: x - particle.width / 2,
                y: y - particle.height / 2,
                width: particle.width,
                height: particle.height
            )

            var path = Path()
            if particle.id.isMultiple(of: 3) {
                path.addEllipse(in: rect)
            } else {
                path.addRect(rect)
            }
            context.fill(path, with: .color(particle.color.opacity(opacity)))
        }
    }
}

private struct ConfettiParticle: Identifiable {
    let id: Int
    let color: Color
    let horizontalVelocity: Double
    let upwardVelocity: Double
    let delay: Double
    let width: Double
    let height: Double
    let phase: Double

    static let all: [ConfettiParticle] = {
        let colors: [Color] = [
            AppTheme.standout,
            AppTheme.accent,
            .green,
            .yellow,
            .pink,
            .cyan
        ]
        return (0..<72).map { index in
            let horizontalSeed = (index * 73) % 101
            let verticalSeed = (index * 47) % 101
            let sizeSeed = (index * 29) % 5
            return ConfettiParticle(
                id: index,
                color: colors[index % colors.count],
                horizontalVelocity: Double(horizontalSeed - 50) * 3.2,
                upwardVelocity: 560 + Double(verticalSeed) * 3.1,
                delay: Double(index % 12) * 0.018,
                width: 5 + Double(sizeSeed),
                height: 9 + Double((sizeSeed + 2) % 5),
                phase: Double(index) * 0.71
            )
        }
    }()
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

private struct BalanceSummaryView: View {
    let totals: ReconciliationTotals
    let accountBalances: AccountBalances?

    private var upCents: Int {
        accountBalances?.upCents ?? totals.upTotalCents
    }

    private var ynabCents: Int {
        accountBalances?.ynabCents ?? totals.ynabTotalCents
    }

    private var differenceCents: Int {
        accountBalances?.differenceCents ?? totals.gapCents
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                BalanceValueView(title: "Up", cents: upCents)
                Spacer()
                BalanceValueView(title: "YNAB", cents: ynabCents)
                Spacer()
                BalanceValueView(title: "Difference", cents: differenceCents, emphasized: true)
            }
            VStack(alignment: .leading) {
                BalanceValueView(title: "Up", cents: upCents)
                BalanceValueView(title: "YNAB", cents: ynabCents)
                BalanceValueView(title: "Difference", cents: differenceCents, emphasized: true)
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

private struct SentHistorySection: View {
    let group: ActionGroup
    @State private var isExpanded = false

    var body: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sent to YNAB")
                            .font(.headline)
                            .foregroundStyle(.green)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sent to YNAB, \(summary)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses sent transactions" : "Shows sent transactions")

            if isExpanded {
                ForEach(group.rows) { row in
                    SentHistoryRow(row: row)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .listRowBackground(AppTheme.card.opacity(isExpanded ? 0.78 : 0.58))
        .listRowSeparatorTint(.white.opacity(0.12))
    }

    private var summary: String {
        let noun = group.rows.count == 1 ? "transaction" : "transactions"
        return "\(group.rows.count) \(noun) · $\(Money(cents: group.subtotalCents).formatted)"
    }
}

private struct SentHistoryRow: View {
    let row: ActionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.title)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Spacer()
                Text(verbatim: "$\(Money(cents: row.balanceEffectCents).formatted)")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.86))
            }
            Text(row.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack {
                Text(row.date.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Sent")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ActionGroupSection<Destination: View>: View {
    let group: ActionGroup
    let model: ReconcileViewModel
    @ViewBuilder let destination: (ActionRow) -> Destination

    var body: some View {
        Section {
            ForEach(group.rows) { row in
                ActionRowContainer(
                    row: row,
                    model: model,
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
    let model: ReconcileViewModel
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        let locked = model.isLocked(row)
        let categoryRequired = row.isSendable && model.draft(for: row).categoryID == nil

        HStack(alignment: .top, spacing: 12) {
            if row.isSendable && !locked {
                SendSelectionButton(model: model, row: row)
                    .padding(.top, 2)
            }

            if row.isSendable {
                CardNavigationLink(destination: destination) {
                    ActionRowLabel(
                        row: row,
                        status: categoryRequired ? .categoryRequired : .none
                    )
                }
                .accessibilityLabel("View details for \(row.title)")
                .accessibilityHint("Opens transaction details")
            } else {
                ActionRowLabel(row: row, status: .none)
            }

            if row.isSendable && !locked {
                HStack(spacing: 0) {
                    Divider()

                    if categoryRequired {
                        CategorySelectionLink(model: model, row: row)
                    } else {
                        DetailsChevronLink(
                            title: row.title,
                            destination: destination
                        )
                    }
                }
            }
        }
    }
}

private struct CardNavigationLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            label()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .navigationDestination(isPresented: $isPresented) {
            destination()
        }
    }
}

private struct DetailsChevronLink<Destination: View>: View {
    let title: String
    @ViewBuilder let destination: () -> Destination
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 52, maxWidth: 52, minHeight: 44, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .accessibilityLabel("View details for \(title)")
        .accessibilityHint("Opens transaction details")
        .navigationDestination(isPresented: $isPresented) {
            destination()
        }
    }
}

private struct CategorySelectionLink: View {
    let model: ReconcileViewModel
    let row: ActionRow
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "chevron.right")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 52, maxWidth: 52, minHeight: 44, maxHeight: .infinity)
        .contentShape(Rectangle())
        .clipped()
        .accessibilityLabel("Choose a category for \(row.title)")
        .accessibilityHint("Opens the YNAB category list")
        .navigationDestination(isPresented: $isPresented) {
            CategoryPickerView(model: model, row: row)
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)
                Spacer()
                Text(verbatim: "$\(Money(cents: row.balanceEffectCents).formatted)")
                    .font(.body.monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(row.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
