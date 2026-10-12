import SwiftUI

enum AppTheme {
    static let card = Color(red: 14 / 255, green: 16 / 255, blue: 40 / 255)
    static let featureCard = Color(red: 35 / 255, green: 42 / 255, blue: 91 / 255)
    static let accent = Color(red: 115 / 255, green: 124 / 255, blue: 255 / 255)
    static let standout = Color(red: 255 / 255, green: 126 / 255, blue: 45 / 255)
}

struct AppGradientBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 68 / 255, green: 55 / 255, blue: 184 / 255),
                    Color(red: 50 / 255, green: 106 / 255, blue: 160 / 255),
                    Color(red: 0 / 255, green: 168 / 255, blue: 117 / 255)
                ],
                startPoint: .topLeading,
                endPoint: .topTrailing
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.25),
                    .init(color: Color(red: 7 / 255, green: 19 / 255, blue: 41 / 255), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

private struct AppListSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppGradientBackground())
            .environment(\.colorScheme, .dark)
            .tint(AppTheme.accent)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension View {
    func appListSurface() -> some View {
        modifier(AppListSurfaceModifier())
    }

    func appCardRows() -> some View {
        listRowBackground(AppTheme.card.opacity(0.96))
    }
}
