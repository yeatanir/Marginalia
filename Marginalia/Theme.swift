import Combine
import SwiftUI

// MARK: - Appearance

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Accent Palette

enum AccentPalette: String, CaseIterable, Identifiable {
    case ink, forest, ember, slate, plum
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ink:    return "Ink"
        case .forest: return "Forest"
        case .ember:  return "Ember"
        case .slate:  return "Slate"
        case .plum:   return "Plum"
        }
    }

    var accent: Color {
        switch self {
        case .ink:    return Color(hex: "4C5FD5")
        case .forest: return Color(hex: "3E8E6E")
        case .ember:  return Color(hex: "C2613E")
        case .slate:  return Color(hex: "5A6472")
        case .plum:   return Color(hex: "8A5A9E")
        }
    }
}

// MARK: - Theme Manager

final class ThemeManager: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    @AppStorage("appearance") var appearanceRaw: String = AppAppearance.system.rawValue {
        willSet { objectWillChange.send() }
    }
    @AppStorage("palette") var paletteRaw: String = AccentPalette.ink.rawValue {
        willSet { objectWillChange.send() }
    }

    var appearance: AppAppearance {
        get { AppAppearance(rawValue: appearanceRaw) ?? .system }
        set { appearanceRaw = newValue.rawValue }
    }

    var palette: AccentPalette {
        get { AccentPalette(rawValue: paletteRaw) ?? .ink }
        set { paletteRaw = newValue.rawValue }
    }

    var accent: Color { palette.accent }
    func accentSoft(_ scheme: ColorScheme) -> Color {
        palette.accent.opacity(scheme == .dark ? 0.18 : 0.12)
    }
}

// MARK: - Semantic Color Tokens
// Use these in views, never raw colors. Each resolves for light/dark.

struct Theme {
    let scheme: ColorScheme

    var bgPrimary: Color    { c(light: "FAFAF8", dark: "0E0E10") }
    var bgSurface: Color    { c(light: "FFFFFF", dark: "1A1A1D") }
    var bgSurfaceAlt: Color { c(light: "F2F2EF", dark: "242428") }

    var textPrimary: Color   { c(light: "1A1A1A", dark: "F5F5F3") }
    var textSecondary: Color { c(light: "6B6B6B", dark: "9A9A9A") }
    var textTertiary: Color  { c(light: "A0A0A0", dark: "6A6A6A") }

    var separator: Color { c(light: "E5E5E2", dark: "2E2E32") }

    var highlightYellow: Color { c(light: "FFE9A8", dark: "5C4F1E") }

    private func c(light: String, dark: String) -> Color {
        Color(hex: scheme == .dark ? dark : light)
    }
}

// Convenience: read the current theme from the environment color scheme.
private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme(scheme: .light)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// Apply this modifier high in the view tree so `@Environment(\.theme)` works.
struct ThemeProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.theme, Theme(scheme: scheme))
    }
}

extension View {
    func provideTheme() -> some View { modifier(ThemeProvider()) }
}

// MARK: - Color hex init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (0, 0, 0)
        }
        self.init(
            .sRGB,
            red:   Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: 1
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss

    @AppStorage("backendURL") private var backendURL = BackendService.defaultBaseURL

    var body: some View {
        NavigationView {
            List {
                Section("Appearance") {
                    Picker("Mode", selection: Binding(
                        get: { theme.appearance },
                        set: { theme.appearance = $0 }
                    )) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Accent") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 16) {
                        ForEach(AccentPalette.allCases) { palette in
                            Button {
                                theme.palette = palette
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(palette.accent)
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .stroke(t.textPrimary, lineWidth: theme.palette == palette ? 2 : 0)
                                                .padding(-3)
                                        )
                                    Text(palette.label)
                                        .font(.caption2)
                                        .foregroundColor(t.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section {
                    TextField("http://100.x.x.x:8000", text: $backendURL)
                        .font(.system(.callout, design: .monospaced))
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Backend")
                } footer: {
                    Text("Mac Mini Tailscale IP and port. Run tailscale ip -4 on the Mac Mini. Takes effect immediately — no recompile needed.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
