import SwiftUI
import TransactionKit

struct SplitPickerView: View {
    let model: ReconcileViewModel
    let depositID: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if let block = model.splitBlock(depositID: depositID) {
                    SplitSummarySection(model: model, block: block)

                    if let selectedRow = selectedActionRow {
                        Section {
                            NavigationLink {
                                RowDetailView(model: model, row: selectedRow)
                            } label: {
                                Label("Edit payee and category", systemImage: "square.and.pencil")
                            }
                        }
                    }

                    Section("Ranked candidates") {
                        ForEach(block.candidates, id: \.purchaseID) { candidate in
                            Button {
                                model.selectCandidate(
                                    depositID: depositID,
                                    purchaseID: candidate.purchaseID
                                )
                                dismiss()
                            } label: {
                                SplitCandidateRow(
                                    title: model.transaction(upID: candidate.purchaseID)?.description ?? "Purchase",
                                    candidate: candidate,
                                    isSelected: block.chosenPurchaseID == candidate.purchaseID
                                )
                            }
                            .foregroundStyle(.primary)
                            .accessibilityLabel(candidateAccessibilityLabel(candidate, block: block))
                            .accessibilityAddTraits(
                                block.chosenPurchaseID == candidate.purchaseID ? .isSelected : []
                            )
                        }
                    }

                    Section {
                        if model.hasManualSplitSelection(depositID: depositID) {
                            Button("Use recommended match") {
                                model.resetSplitToAutomatic(depositID: depositID)
                                dismiss()
                            }
                            .tint(AppTheme.standout)
                        }
                        Button("Not a split") {
                            model.rejectSplit(depositID: depositID)
                            dismiss()
                        }
                        .tint(AppTheme.standout)
                        .accessibilityHint("Returns the purchase and repayment as separate rows")
                    }
                    } else {
                        ContentUnavailableView(
                            "Split unavailable",
                            systemImage: "questionmark.circle",
                            description: Text("This repayment is no longer in the split shortlist.")
                        )
                    }
                }
                .appCardRows()
            }
            .appListSurface()
            .navigationTitle("Choose purchase")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var selectedActionRow: ActionRow? {
        model.actionGroups
            .first(where: { $0.id == .share })?
            .rows.first(where: { $0.id == depositID && $0.isSendable })
    }

    private func candidateAccessibilityLabel(_ candidate: ShareCandidate, block: ShareBlock) -> String {
        let title = model.transaction(upID: candidate.purchaseID)?.description ?? "Purchase"
        let selected = block.chosenPurchaseID == candidate.purchaseID ? ", selected" : ""
        let reasons = candidate.reasons.formatted(.list(type: .and))
        return "\(title), score \(candidate.score), your share $\(Money(cents: candidate.yourShareCents).formatted)\(selected), \(reasons)"
    }
}

private struct SplitSummarySection: View {
    let model: ReconcileViewModel
    let block: ShareBlock

    var body: some View {
        Section {
            LabeledContent("Repayment") {
                Text(verbatim: "$\(Money(cents: block.depositCents).formatted)")
            }
            if let share = block.yourShareCents {
                LabeledContent("Your share") {
                    Text(verbatim: "$\(Money(cents: share).formatted)")
                }
            } else {
                Label("No purchase is selected", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text("Scores rank the shortlist. Evidence bands decide whether a purchase can be selected automatically.")
        }
    }
}

private struct SplitCandidateRow: View {
    let title: String
    let candidate: ShareCandidate
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.body)
                Spacer()
                Text("Score \(candidate.score)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: "Your share $\(Money(cents: candidate.yourShareCents).formatted)")
                .font(.subheadline)
            Text(candidate.reasons.formatted(.list(type: .and)))
                .font(.caption)
                .foregroundStyle(.secondary)
            if isSelected {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }
}

#Preview("Split picker · Tie") {
    let model = ReconcileViewModel.fixturePreview()
    SplitPickerView(model: model, depositID: "d24d7cf8-08dd-5091-9498-793708427e2d")
}

#Preview("Split picker · AX5") {
    let model = ReconcileViewModel.fixturePreview()
    SplitPickerView(model: model, depositID: "b7dccf1f-8d90-5c28-92a9-8491526f6263")
        .environment(\.dynamicTypeSize, .accessibility5)
}
