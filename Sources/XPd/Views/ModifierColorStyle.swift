import SwiftUI

/// SwiftUI-only treatment for the persisted modifier palette. Keeping this
/// mapping out of the model keeps Codable state independent of AppKit/SwiftUI.
extension ModifierColor {
    var swiftUIColor: Color {
        switch self {
        case .orange:
            Color(red: 1.0, green: 0.48, blue: 0.08)
        case .yellow:
            Color(red: 1.0, green: 0.82, blue: 0.18)
        case .cyan:
            Color(red: 0.18, green: 0.84, blue: 0.92)
        case .blue:
            Color(red: 0.30, green: 0.52, blue: 1.0)
        case .purple:
            Color(red: 0.72, green: 0.42, blue: 1.0)
        case .pink:
            Color(red: 1.0, green: 0.35, blue: 0.66)
        }
    }
}
