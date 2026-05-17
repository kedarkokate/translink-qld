import SwiftUI

/// User-selectable colour-scheme override. Persisted as a string via
/// @AppStorage so it survives app relaunches.
///
///  - `system`: follow the iOS-level Light/Dark setting (default).
///  - `light` / `dark`: force the chosen scheme regardless of system setting.
enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    static let storageKey = "appearance_mode_v1"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var iconName: String {
        switch self {
        case .system: return "gearshape"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// Maps to SwiftUI's `.preferredColorScheme` argument. `nil` means
    /// "inherit from the system" — the only way to release SwiftUI's
    /// override and follow the iOS-level appearance setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
