import SwiftUI

@MainActor
struct ContentView: View {
    private enum AppTab: Hashable {
        case reconcile
        case settings
    }

    @State private var model: ReconcileViewModel
    @State private var selectedTab: AppTab = .reconcile

    @MainActor
    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-FixtureData") {
            _model = State(initialValue: .fixtureLaunch(refreshFails: arguments.contains("-FixtureRefreshFails")))
            return
        }
        #endif
        _model = State(initialValue: ReconcileViewModel())
    }

    @MainActor
    init(model: ReconcileViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Reconcile", systemImage: "checklist", value: .reconcile) {
                ReconcileView(model: model)
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                SettingsView(model: model) {
                    selectedTab = .reconcile
                }
            }
        }
        .tint(AppTheme.accent)
        .toolbarColorScheme(.dark, for: .tabBar)
        .toolbarBackground(.hidden, for: .tabBar)
        .preferredColorScheme(.light)
    }
}

#Preview("Fixture app") {
    ContentView(model: .fixturePreview())
}
