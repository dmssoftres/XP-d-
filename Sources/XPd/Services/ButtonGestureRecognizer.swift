import Foundation

struct ButtonGestureTiming: Equatable {
    static let standard = ButtonGestureTiming(
        holdThreshold: 0.50,
        doubleTapInterval: 0.20
    )

    let holdThreshold: TimeInterval
    let doubleTapInterval: TimeInterval
}

/// Everything that makes two physical presses eligible to form one Double.
/// K layers and keyboard/F-key gates are part of the identity so separate
/// mappings can never be merged into a hybrid gesture.
struct ButtonGestureIdentity: Hashable {
    let control: RemoteControl
    let modifierControls: Set<RemoteControl>
    let keyboardModifiers: Set<KeyboardShortcut.Modifier>
    let functionKeys: Set<UInt16>
    /// Ordinary keyboard keys held when the physical remote control was
    /// pressed.  This is separate from `functionKeys` for compatibility with
    /// the legacy F1…F12 trigger field.
    let keyboardKeys: Set<UInt16>

    init(
        control: RemoteControl,
        modifierControls: Set<RemoteControl> = [],
        keyboardModifiers: Set<KeyboardShortcut.Modifier> = [],
        functionKeys: Set<UInt16> = [],
        keyboardKeys: Set<UInt16> = []
    ) {
        self.control = control
        self.modifierControls = modifierControls
        self.keyboardModifiers = keyboardModifiers
        self.functionKeys = functionKeys
        self.keyboardKeys = keyboardKeys
    }
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

    var onGesture: ((ButtonGestureIdentity, GestureKind) -> Void)?

    private let timing: ButtonGestureTiming
    private let schedule: Schedule
    private var states: [ButtonGestureIdentity: ControlState] = [:]

    init(
        timing: ButtonGestureTiming = .standard,
        schedule: @escaping Schedule = ButtonGestureRecognizer.productionSchedule
    ) {
        self.timing = timing
        self.schedule = schedule
    }

    func press(_ identity: ButtonGestureIdentity) {
        var state = states[identity] ?? ControlState()
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
            self?.recognizeHold(for: identity, generation: generation)
        }
        states[identity] = state
    }

    func release(_ identity: ButtonGestureIdentity) {
        guard var state = states[identity], state.isPressed else { return }

        state.isPressed = false
        state.holdAction?.cancel()
        state.holdAction = nil

        if state.holdRecognized {
            state.tapAction?.cancel()
            states.removeValue(forKey: identity)
            return
        }

        if state.isSecondPress {
            state.tapAction?.cancel()
            states.removeValue(forKey: identity)
            onGesture?(identity, .doubleTap)
            return
        }

        state.awaitingSecondTap = true
        state.generation += 1
        let generation = state.generation
        state.tapAction = schedule(timing.doubleTapInterval) { [weak self] in
            self?.recognizeTap(for: identity, generation: generation)
        }
        states[identity] = state
    }

    /// Moves a still-held physical press to a newly resolved exact identity.
    /// If the old press was tentatively the second half of a Double, restore
    /// its first Tap rather than discarding it when a K layer joins late.
    func reclassifyPress(
        from oldIdentity: ButtonGestureIdentity,
        to newIdentity: ButtonGestureIdentity
    ) -> Bool {
        guard oldIdentity != newIdentity,
              var oldState = states[oldIdentity],
              oldState.isPressed,
              !oldState.holdRecognized else { return false }

        oldState.holdAction?.cancel()
        oldState.holdAction = nil
        oldState.isPressed = false

        if oldState.isSecondPress {
            oldState.isSecondPress = false
            oldState.awaitingSecondTap = true
            oldState.holdRecognized = false
            oldState.generation += 1
            let generation = oldState.generation
            oldState.tapAction = schedule(timing.doubleTapInterval) { [weak self] in
                self?.recognizeTap(for: oldIdentity, generation: generation)
            }
            states[oldIdentity] = oldState
        } else {
            oldState.tapAction?.cancel()
            states.removeValue(forKey: oldIdentity)
        }

        press(newIdentity)
        return true
    }

    func cancel(_ identity: ButtonGestureIdentity) {
        guard let state = states.removeValue(forKey: identity) else { return }
        state.holdAction?.cancel()
        state.tapAction?.cancel()
    }

    // Convenience overloads keep direct recognizer callers concise.
    func press(_ control: RemoteControl) { press(ButtonGestureIdentity(control: control)) }
    func release(_ control: RemoteControl) { release(ButtonGestureIdentity(control: control)) }
    func cancel(_ control: RemoteControl) { cancel(ButtonGestureIdentity(control: control)) }

    func cancelAll() {
        let identities = Array(states.keys)
        for identity in identities {
            cancel(identity)
        }
    }

    private func recognizeHold(for identity: ButtonGestureIdentity, generation: Int) {
        guard var state = states[identity],
              state.generation == generation,
              state.isPressed else { return }

        state.holdRecognized = true
        state.awaitingSecondTap = false
        state.isSecondPress = false
        state.tapAction?.cancel()
        state.tapAction = nil
        state.holdAction = nil
        states[identity] = state
        onGesture?(identity, .hold)
    }

    private func recognizeTap(for identity: ButtonGestureIdentity, generation: Int) {
        guard let state = states[identity],
              state.generation == generation,
              state.awaitingSecondTap,
              !state.isPressed else { return }

        states.removeValue(forKey: identity)
        onGesture?(identity, .tap)
    }
}
