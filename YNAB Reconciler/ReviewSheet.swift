import SwiftUI
import TransactionKit

struct ReviewSheet: View {
    let model: ReconcileViewModel
    let review: SendReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                    ForEach(review.rows) { row in
                        ReviewTransactionRow(row: row)
                    }
                } header: {
                    Text("\(review.rows.count) transactions")
                }

                if model.settings.dryRun {
                    Section("Exact JSON payload") {
                        Text(verbatim: review.payloadJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                    if let message = model.sendResultMessage {
                        Section {
                            Text(message)
                                .foregroundStyle(
                                    model.settings.dryRun ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                                )
                        }
                    }
                }
                .appCardRows()
            }
            .appListSurface()
            .navigationTitle(model.settings.dryRun ? "Review dry run" : "Review send")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                    .opacity(model.isSending ? 0.32 : 1)
                    .disabled(model.isSending)
                }
            }
            .safeAreaInset(edge: .bottom) {
                ReviewSummaryBar(
                    totalCents: review.totalCents,
                    outstandingCents: review.outstandingAfterCents,
                    isDryRun: model.settings.dryRun,
                    isSending: model.isSending
                ) {
                    _ = Task {
                        await model.confirmSend()
                    }
                }
            }
            .interactiveDismissDisabled(model.isSending)
        }
    }
}

private struct ReviewTransactionRow: View {
    let row: ReviewRow

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                ReviewRowDescription(payee: row.payee, category: row.category, date: row.date)
                Spacer()
                Text(verbatim: "$\(Money(cents: row.cents).formatted)")
                    .font(.body.monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 4) {
                ReviewRowDescription(payee: row.payee, category: row.category, date: row.date)
                Text(verbatim: "$\(Money(cents: row.cents).formatted)")
                    .font(.body.monospacedDigit())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.date.description), \(row.payee), \(row.category)"
        )
        .accessibilityValue("$\(Money(cents: row.cents).formatted)")
    }
}

private struct ReviewRowDescription: View {
    let payee: String
    let category: String
    let date: LocalDate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(payee)
            Text(category)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(date.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReviewSummaryBar: View {
    let totalCents: Int
    let outstandingCents: Int
    let isDryRun: Bool
    let isSending: Bool
    let confirm: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top) {
                    ReviewTotal(title: "YNAB move", cents: totalCents)
                    Spacer()
                    ReviewTotal(title: "Afterwards", cents: outstandingCents)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        ReviewTotal(title: "YNAB will move", cents: totalCents)
                        Spacer()
                        ReviewTotal(title: "Outstanding afterwards", cents: outstandingCents)
                    }
                    VStack(alignment: .leading) {
                        ReviewTotal(title: "YNAB will move", cents: totalCents)
                        ReviewTotal(title: "Outstanding afterwards", cents: outstandingCents)
                    }
                }
            }
            Button(buttonTitle) {
                confirm()
            }
                .padding(.top, 20)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AppTheme.standout)
                .foregroundStyle(.white)
                .disabled(isSending)
                .opacity(isSending ? 0.32 : 1)
                .frame(maxWidth: .infinity)
                .accessibilityHint(
                    isDryRun
                        ? "Validates and reports this payload without sending"
                        : "Creates all reviewed transactions as one YNAB batch"
                )
        }
        .padding()
        .background(
            AppTheme.featureCard.opacity(0.98),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var buttonTitle: LocalizedStringKey {
        if dynamicTypeSize.isAccessibilitySize {
            return isDryRun ? "Dry run" : "Send"
        }
        return isDryRun ? "Run dry run" : "Send to YNAB"
    }
}

private struct ReviewTotal: View {
    let title: LocalizedStringKey
    let cents: Int
    var compact = false

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(verbatim: "$\(Money(cents: cents).formatted)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(verbatim: "$\(Money(cents: cents).formatted)")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Review · Dry run") {
    ReviewSheet(model: .dryRunFixturePreview(), review: .fixturePreview())
}
