import Observation
import SwiftUI

struct SettingsView: View {
    private enum FocusedField: Hashable {
        case upToken
        case ynabToken
        case ynabPlanID
        case ynabAccountID
        case upAccountID
        case partnerHandles
    }

    @Bindable var model: ReconcileViewModel
    let didSave: () -> Void
    @State private var showsClearLogWarning = false
    @FocusState private var focusedField: FocusedField?

    init(model: ReconcileViewModel, didSave: @escaping () -> Void = {}) {
        self.model = model
        self.didSave = didSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section("Credentials") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Up API token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SecureField("Enter Up API token", text: $model.upToken)
                                .textContentType(.password)
                                .focused($focusedField, equals: .upToken)
                                .accessibilityLabel("Up API token")
                                .accessibilityHint("Stored only in the device Keychain")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YNAB API token")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            SecureField("Enter YNAB API token", text: $model.ynabToken)
                                .textContentType(.password)
                                .focused($focusedField, equals: .ynabToken)
                                .accessibilityLabel("YNAB API token")
                                .accessibilityHint("Stored only in the device Keychain")
                        }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YNAB plan ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Enter YNAB plan ID", text: $model.settings.ynabPlanID)
                            .focused($focusedField, equals: .ynabPlanID)
                            .accessibilityLabel("YNAB plan ID")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YNAB account ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Enter YNAB account ID", text: $model.settings.ynabAccountID)
                            .focused($focusedField, equals: .ynabAccountID)
                            .accessibilityLabel("YNAB account ID")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Up account ID (optional)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Enter Up account ID", text: $model.settings.upAccountID)
                            .focused($focusedField, equals: .upAccountID)
                            .accessibilityLabel("Up account ID, optional")
                    }
                    DatePicker(
                        "Start date",
                        selection: $model.settings.startDate,
                        displayedComponents: .date
                    )
                    .accessibilityLabel("Start date")
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Plan and account IDs are not secret and are stored in app settings.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Partner handles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Enter Up display names", text: $model.settings.partnerHandles, axis: .vertical)
                            .focused($focusedField, equals: .partnerHandles)
                            .accessibilityLabel("Partner handles")
                            .accessibilityHint("Separate multiple handles with commas")
                    }
                    if model.settings.partners.isEmpty {
                        Text("Without partner handles, every inflow can be treated as a repayment.")
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Shared costs")
                } footer: {
                    Text("Separate multiple Up display names with commas.")
                }

                Section {
                    Stepper(
                        "Date tolerance: \(model.settings.tolerance) days",
                        value: $model.settings.tolerance,
                        in: 0...30
                    )
                    Stepper(
                        "Reimbursement window: \(model.settings.reimbursementWindow) days",
                        value: $model.settings.reimbursementWindow,
                        in: 1...60
                    )
                    Stepper(
                        "Settlement window: \(model.settings.settleWindow) days",
                        value: $model.settings.settleWindow,
                        in: 1...90
                    )
                } header: {
                    Text("Matching")
                } footer: {
                    Text("Defaults: 7-day tolerance, 14-day reimbursement window, and 30-day settlement window.")
                }

                Section {
                    Stepper(
                        "Tolerance: \(model.settings.amendToleranceCents) cents",
                        value: $model.settings.amendToleranceCents,
                        in: 1...1_000
                    )
                    Stepper(
                        "Date window: \(model.settings.amendDays) days",
                        value: $model.settings.amendDays,
                        in: 1...30
                    )
                } header: {
                    Text("Amount corrections")
                } footer: {
                    Text("Defaults: 100 cents over 3 days.")
                }

                Section {
                    Stepper(
                        "Score floor: \(model.settings.scoreFloor)",
                        value: $model.settings.scoreFloor,
                        in: 0...100
                    )
                    Stepper(
                        "Shortlist size: \(model.settings.shortlistSize)",
                        value: $model.settings.shortlistSize,
                        in: 1...20
                    )
                } header: {
                    Text("Split ranking")
                } footer: {
                    Text("Defaults: minimum score 25 and up to 5 candidates.")
                }

                Section {
                    Picker("YNAB cleared status", selection: $model.settings.heldStatus) {
                        Text("Cleared").tag("cleared")
                        Text("Uncleared").tag("uncleared")
                    }
                } header: {
                    Text("Pending transactions")
                } footer: {
                    Text("The specification default is cleared.")
                }

                Section {
                    Toggle("Dry run", isOn: $model.settings.dryRun)
                        .accessibilityHint("Builds and reports the exact payload without sending it")
                    LabeledContent("Logged Up transactions", value: "\(model.pushedLog.count)")
                    Button("Clear pushed log", role: .destructive) {
                        showsClearLogWarning = true
                    }
                    .disabled(model.pushedLog.isEmpty && !model.pushedLogNeedsReset)
                } header: {
                    Text("Sending")
                } footer: {
                    Text("Clearing the log unlocks sent rows. Sending them again will create duplicates in YNAB.")
                }

                    if let message = model.statusMessage {
                        Section {
                            Label(message, systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .appCardRows()
            }
            .appListSurface()
            .toolbarBackground(.hidden, for: .tabBar)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        focusedField = nil
                        if model.saveSettings() {
                            didSave()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.standout)
                    .foregroundStyle(.white)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .confirmationDialog(
                "Clear pushed log?",
                isPresented: $showsClearLogWarning,
                titleVisibility: .visible
            ) {
                Button("Clear log", role: .destructive) {
                    model.clearPushedLog()
                }
            } message: {
                Text("Previously sent rows will unlock. Re-sending them will duplicate transactions in YNAB.")
            }
        }
    }
}

#Preview("Settings") {
    SettingsView(model: .fixturePreview())
}

#Preview("Settings · AX5") {
    SettingsView(model: .fixturePreview())
        .environment(\.dynamicTypeSize, .accessibility5)
}
