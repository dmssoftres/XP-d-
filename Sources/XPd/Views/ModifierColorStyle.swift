import SwiftUI

/// SwiftUI-only treatment for the persisted modifier palette. Keeping this
/// mapping out of the model keeps Codable state independent of AppKit/SwiftUI.
extension ModifierColor {
    var swiftUIColor: Color {
        switch self {
        case .red:
            Color(red: 1.0, green: 0.08, blue: 0.08)
        case .orange:
            Color(red: 1.0, green: 0.35, blue: 0.0)
        case .yellow:
            Color(red: 1.0, green: 0.88, blue: 0.0)
        case .green:
            Color(red: 0.12, green: 0.92, blue: 0.22)
        case .cyan:
            Color(red: 0.0, green: 0.90, blue: 1.0)
        case .blue:
            Color(red: 0.10, green: 0.42, blue: 1.0)
        case .purple:
            Color(red: 0.72, green: 0.20, blue: 1.0)
        case .pink:
            Color(red: 1.0, green: 0.12, blue: 0.56)
        }
    }
}
