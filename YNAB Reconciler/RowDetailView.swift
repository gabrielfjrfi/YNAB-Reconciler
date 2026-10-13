import Networking
import SwiftUI
import TransactionKit

struct RowDetailView: View {
    let model: ReconcileViewModel
    let row: ActionRow
    @State private var payee: String
    @State private var suggestions: [String] = []

    init(model: ReconcileViewModel, row: ActionRow) {
        self.model = model
        self.row = row
        _payee = State(initialValue: model.draft(for: row).payee)
    }

    var body: some View {
        Form {
            Group {
                Section("Transaction") {
                LabeledContent("Date", value: row.date.description)
                LabeledContent("Amount") {
                    Text(verbatim: "$\(Money(cents: row.balanceEffectCents).formatted)")
                }
            }

            if row.kind == .share {
                Section {
                    NavigationLink {
                        SplitPickerView(model: model, depositID: row.id)
                    } label: {
                        Label("Review split match", systemImage: "arrow.triangle.branch")
                    }
                    .accessibilityHint("Opens the ranked split candidates")
                }
            }

            Section("Payee") {
                TextField("Payee name", text: $payee)
                    .textContentType(.organizationName)
                    .accessibilityHint("Free text is allowed")
                    .onChange(of: payee, initial: true) { _, newValue in
                        model.setPayee(newValue, for: row.id)
                        updateSuggestions(for: newValue)
                    }
                if !suggestions.isEmpty {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            payee = suggestion
                        }
                        .accessibilityLabel("Use payee \(suggestion)")
                    }
                }
            }

                Section {
                    NavigationLink {
                        CategoryPickerView(model: model, row: row)
                    } label: {
                        LabeledContent("Category") {
                            Text(model.draft(for: row).categoryName ?? "Required")
                                .foregroundStyle(
                                    model.draft(for: row).categoryID == nil ? .red : .secondary
                                )
                        }
                    }
                    .accessibilityHint("Choose a category from the YNAB category list")
                } footer: {
                    Text("A category must be selected from YNAB. Typed category names are not accepted.")
                }
            }
            .appCardRows()
        }
        .appListSurface()
        .navigationTitle("Transaction details")
    }

    private func updateSuggestions(for query: String) {
        guard !query.isEmpty else {
            suggestions = Array(model.payees.prefix(5))
            return
        }
        suggestions = Array(model.payees.lazy.filter {
            $0.localizedCaseInsensitiveContains(query) && $0.caseInsensitiveCompare(query) != .orderedSame
        }.prefix(5))
    }
}

struct CategoryPickerView: View {
    let model: ReconcileViewModel
    let row: ActionRow
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var visibleGroups: [YNABCategoryGroup]

    init(model: ReconcileViewModel, row: ActionRow) {
        self.model = model
        self.row = row
        _visibleGroups = State(initialValue: model.categories)
    }

    var body: some View {
        List {
            Group {
                ForEach(visibleGroups, id: \.id) { group in
                Section {
                    ForEach(group.categories, id: \.id) { category in
                        Button {
                            model.setCategory(category, for: row)
                            dismiss()
                        } label: {
                            HStack {
                                Text(category.name)
                                Spacer()
                                if model.selectedCategory(for: row)?.id == category.id {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel(category.name)
                        .accessibilityAddTraits(
                            model.selectedCategory(for: row)?.id == category.id ? .isSelected : []
                        )
                    }
                } header: {
                    Text(group.name)
                        .accessibilityAddTraits(.isHeader)
                }
                }
            }
            .appCardRows()
        }
        .appListSurface()
        .navigationTitle("Category")
        .searchable(text: $searchText, prompt: "Search categories")
        .onChange(of: searchText, initial: true) { _, query in
            updateVisibleGroups(query: query)
        }
        .overlay {
            if visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }

    private func updateVisibleGroups(query: String) {
        guard !query.isEmpty else {
            visibleGroups = model.categories
            return
        }
        visibleGroups = model.categories.compactMap { group in
            let matches = group.categories.filter { $0.name.localizedCaseInsensitiveContains(query) }
            guard !matches.isEmpty else { return nil }
            return YNABCategoryGroup(id: group.id, name: group.name, categories: matches)
        }
    }
}

#Preview("Row detail") {
    let model = ReconcileViewModel.fixturePreview()
    let row = model.actionGroups.first(where: { $0.id == .add })!.rows.first!
    NavigationStack {
        RowDetailView(model: model, row: row)
    }
}

#Preview("Category picker · Dark") {
    let model = ReconcileViewModel.fixturePreview()
    let row = model.actionGroups.first(where: { $0.id == .add })!.rows.first!
    NavigationStack {
        CategoryPickerView(model: model, row: row)
    }
    .preferredColorScheme(.dark)
}
