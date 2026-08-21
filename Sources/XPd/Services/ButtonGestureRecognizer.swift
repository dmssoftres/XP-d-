import Foundation

struct ButtonGestureTiming: Equatable {
    static let standard = ButtonGestureTiming(
        holdThreshold: 0.72,
        doubleTapInterval: 0.30
    )

    let holdThreshold: TimeInterval
    let doubleTapInterval: TimeInterval
}

@MainActor
final class GestureScheduledAction {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

/// Converts the remote's verified button-down/signature and generic-release
/// stream into mutually exclusive Tap, Hold, and Double gestures.
@MainActor
final class ButtonGestureRecognizer {
    typealias Schedule = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> GestureScheduledAction

    private struct ControlState {
        var isPressed = false
        var isSecondPress = false
        var holdRecognized = false
        var awaitingSecondTap = false
        var generation = 0
        var holdAction: GestureScheduledAction?
        var tapAction: GestureScheduledAction?
    }

    static let productionSchedule: Schedule = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
        return GestureScheduledAction { task.cancel() }
    }

    var onGesture: ((RemoteControl, GestureKind) -> Void)?

    private let timing: ButtonGestureTiming
    private let schedule: Schedule
    private var states: [RemoteControl: ControlState] = [:]

    init(
        timing: ButtonGestureTiming = .standard,
        schedule: @escaping Schedule = ButtonGestureRecognizer.productionSchedule
    ) {
        self.timing = timing
        self.schedule = schedule
    }

    func press(_ control: RemoteControl) {
        var state = states[control] ?? ControlState()
        guard !state.isPressed else { return }

        state.isPressed = true
        state.isSecondPress = state.awaitingSecondTap
        state.holdRecognized = false
        state.generation += 1
        let generation = state.generation

        if state.isSecondPress {
            state.awaitingSecondTap = false
            state.tapAction?.cancel()
            state.tapAction = nil
        }

        state.holdAction = schedule(timing.holdThreshold) { [weak self] in
            self?.recognizeHold(for: control, generation: generation)
        }
        states[control] = state
    }

    func release(_ control: RemoteControl) {
        guard var state = states[control], state.isPressed else { return }

        state.isPressed = false
        state.holdAction?.cancel()
        state.holdAction = nil

        if state.holdRecognized {
            state.tapAction?.cancel()
            states.removeValue(forKey: control)
            return
        }

        if state.isSecondPress {
            state.tapAction?.cancel()
            states.removeValue(forKey: control)
            onGesture?(control, .doubleTap)
            return
        }

        state.awaitingSecondTap = true
        state.generation += 1
        let generation = state.generation
        state.tapAction = schedule(timing.doubleTapInterval) { [weak self] in
            self?.recognizeTap(for: control, generation: generation)
        }
        states[control] = state
    }

    func cancel(_ control: RemoteControl) {
        guard let state = states.removeValue(forKey: control) else { return }
        state.holdAction?.cancel()
        state.tapAction?.cancel()
    }

    func cancelAll() {
        let controls = Array(states.keys)
        for control in controls {
            cancel(control)
        }
    }

    private func recognizeHold(for control: RemoteControl, generation: Int) {
        guard var state = states[control],
              state.generation == generation,
              state.isPressed else { return }

        state.holdRecognized = true
        state.awaitingSecondTap = false
        state.isSecondPress = false
        state.tapAction?.cancel()
        state.tapAction = nil
        state.holdAction = nil
        states[control] = state
        onGesture?(control, .hold)
    }

    private func recognizeTap(for control: RemoteControl, generation: Int) {
        guard let state = states[control],
              state.generation == generation,
              state.awaitingSecondTap,
              !state.isPressed else { return }

        states.removeValue(forKey: control)
        onGesture?(control, .tap)
    }
}
