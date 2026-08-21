import Foundation

enum WheelScrollDirection: Int32, Equatable {
    case up = 1
    case down = -1
}

struct WheelScrollSettings: Equatable {
    static let minimumSensitivity = 1.0
    static let maximumSensitivity = 10.0
    static let defaultSensitivity = 5.0

    let sensitivity: Double

    init(sensitivity: Double = Self.defaultSensitivity) {
        self.sensitivity = Self.clamped(sensitivity)
    }

    func delta(for direction: WheelScrollDirection) -> Int32 {
        direction.rawValue * Int32(sensitivity.rounded())
    }

    static func clamped(_ sensitivity: Double) -> Double {
        guard sensitivity.isFinite else { return defaultSensitivity }
        return min(maximumSensitivity, max(minimumSensitivity, sensitivity))
    }
}
