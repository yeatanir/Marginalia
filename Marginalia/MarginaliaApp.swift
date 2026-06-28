import SwiftUI

@main
struct MarginaliaApp: App {
    @StateObject private var theme = ThemeManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(theme)
                .preferredColorScheme(theme.appearance.colorScheme)
                .tint(theme.palette.accent)
                .provideTheme()
        }
    }
}
