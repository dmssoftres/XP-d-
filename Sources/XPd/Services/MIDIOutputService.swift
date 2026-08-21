import CoreMIDI
import Darwin
import Foundation

// CoreMIDI source IDs are persisted through the thread-safe defaults store;
// this narrow service owns all access after initialization.
extension UserDefaults: @retroactive @unchecked Sendable { }

/// CoreMIDI output is kept behind this small synchronous backend so the
/// stateful service can be tested without publishing endpoints into the host
/// MIDI graph.  Backends are only called from MIDIOutputService's actor.
struct MIDIBackendSource: Sendable, Equatable {
    let endpointID: MIDIUniqueID
    let stableIDWarning: String?
}

protocol MIDIOutputBackend: AnyObject, Sendable {
    func createSource(name: String, preferredUniqueID: MIDIUniqueID?) throws -> MIDIBackendSource
    func send(words: [UInt32], to endpointID: MIDIUniqueID) throws
    func dispose(endpointID: MIDIUniqueID)
}

/// A narrow, protocol-neutral description of button output.  The profile
/// schema can adapt its Codable MIDI mappings to this value without coupling
/// persistence to CoreMIDI.
private enum MIDIOutputButtonBehavior: String, Codable, Sendable {
    case momentary
    case toggle
    case oneShot
}

private enum MIDIOutputButtonMessage: Sendable, Equatable {
    case note(note: UInt8, velocity: UInt8, releaseVelocity: UInt8, behavior: MIDIOutputButtonBehavior)
    case chord(notes: [UInt8], velocity: UInt8, releaseVelocity: UInt8, behavior: MIDIOutputButtonBehavior)
    case controlChange(controller: UInt8, onValue: UInt8, offValue: UInt8, behavior: MIDIOutputButtonBehavior)
    case programChange(program: UInt8)
    case noAction
}

private struct MIDIOutputButtonMapping: Sendable, Equatable {
    let output: MIDIOutputPort
    let channel: UInt8
    let message: MIDIOutputButtonMessage

    init(output: MIDIOutputPort, channel: UInt8, message: MIDIOutputButtonMessage) {
        self.output = output
        self.channel = channel
        self.message = message
    }
}

enum MIDIWheelDirection: Sendable {
    case clockwise
    case counterClockwise

    var opposite: Self {
        switch self {
        case .clockwise: return .counterClockwise
        case .counterClockwise: return .clockwise
        }
    }
}

private enum MIDIOutputWheelMapping: Sendable, Equatable {
    case relativeCC(
        output: MIDIOutputPort,
        channel: UInt8,
        controller: UInt8,
        clockwiseValue: UInt8,
        counterClockwiseValue: UInt8,
        encoding: MIDIRelativeEncoding
    )
    case absoluteCC(
        output: MIDIOutputPort,
        channel: UInt8,
        controller: UInt8,
        initialValue: UInt8,
        step: Int16,
        reversed: Bool
    )
    case pitchBend(
        output: MIDIOutputPort,
        channel: UInt8,
        step: UInt16,
        returnDelay: TimeInterval,
        returnDuration: TimeInterval,
        reversed: Bool
    )
    case transpose
    case drumBank
    case noAction
}

actor MIDIOutputService {
    struct Origin: Hashable, Sendable {
        let identifier: String
        let layer: Int

        init(_ identifier: String, layer: Int = 1) {
            self.identifier = identifier
            self.layer = layer
        }
    }

    struct EndpointStatus: Equatable, Sendable {
        let port: MIDIOutputPort
        let name: String
        let endpointID: MIDIUniqueID?
        let isAvailable: Bool
        let error: String?
    }

    struct SentMessage: Equatable, Sendable {
        let port: MIDIOutputPort
        let word: UInt32
        let summary: String
    }

    struct MonitorEvent: Identifiable, Equatable, Sendable {
        enum Outcome: String, Equatable, Sendable {
            case sent = "SENT"
            case failed = "FAILED"
        }

        let sequence: UInt64
        let timestamp: Date
        let port: MIDIOutputPort
        let word: UInt32
        let summary: String
        let outcome: Outcome
        let error: String?

        var id: UInt64 { sequence }
        var umpHex: String { String(format: "0x%08X", word) }
    }

    enum StateResult: Equatable, Sendable {
        case emitted
        case stateUpdated
        case ignored
    }

    enum ServiceError: LocalizedError, Equatable {
        case invalidChannel(UInt8)
        case invalidPitchBend(Int)
        case endpointUnavailable(MIDIOutputPort)
        case backend(String)

        var errorDescription: String? {
            switch self {
            case let .invalidChannel(channel): return "MIDI channel must be 1...16 (received \(channel))."
            case let .invalidPitchBend(value): return "Pitch Bend must be 0...16383 (received \(value))."
            case let .endpointUnavailable(port): return "MIDI endpoint unavailable: \(port.midiSourceName)."
            case let .backend(message): return message
            }
        }
    }

    private struct ActiveNote: Hashable, Sendable {
        let port: MIDIOutputPort
        let channel: UInt8
        let note: UInt8
        let origin: Origin
        let releaseVelocity: UInt8
        let releaseOnPhysicalRelease: Bool
    }

    private struct ActiveControl: Hashable, Sendable {
        let port: MIDIOutputPort
        let channel: UInt8
        let controller: UInt8
        let offValue: UInt8
        let origin: Origin
    }

    private struct ActiveChannel: Hashable, Sendable {
        let port: MIDIOutputPort
        let channel: UInt8
    }

    private struct WheelKey: Hashable, Sendable {
        let port: MIDIOutputPort
        let channel: UInt8
        let kind: String
        let number: UInt8
    }

    static let controlEndpointDefaultsKey = "XPd.MIDI.endpoint.control.v1"
    static let performanceEndpointDefaultsKey = "XPd.MIDI.endpoint.performance.v1"

    private let backend: any MIDIOutputBackend
    private let defaults: UserDefaults
    private var sources: [MIDIOutputPort: MIDIBackendSource] = [:]
    private(set) var endpointStatuses: [MIDIOutputPort: EndpointStatus] = [:]
    private(set) var lastMessage: SentMessage?
    private(set) var lastError: String?
    private var monitorSequence: UInt64 = 0
    private var monitorSink: (@Sendable (MonitorEvent) -> Void)?
    private var activeNotes: Set<ActiveNote> = []
    private var activeControls: Set<ActiveControl> = []
    private var pressedOrigins: Set<Origin> = []
    private var toggleStates: Set<String> = []
    private var absoluteWheelValues: [WheelKey: UInt8] = [:]
    private var pitchBendValues: [WheelKey: UInt16] = [:]
    private var pitchReturnTasks: [WheelKey: Task<Void, Never>] = [:]
    private var pitchGenerations: [WheelKey: UInt64] = [:]
    private var isDisposed = false

    init(
        defaults: sending UserDefaults = .standard,
        backend: (any MIDIOutputBackend)? = nil
    ) {
        self.defaults = defaults
        if let backend {
            self.backend = backend
        } else if let coreMIDI = try? CoreMIDIOutputBackend() {
            self.backend = coreMIDI
        } else {
            self.backend = UnavailableMIDIOutputBackend()
        }

        for port in MIDIOutputPort.allCases {
            let result = Self.makeSource(for: port, backend: self.backend, defaults: defaults)
            endpointStatuses[port] = result.status
            if let source = result.source { sources[port] = source }
            if let error = result.status.error { lastError = error }
        }
    }

    deinit {
        for task in pitchReturnTasks.values { task.cancel() }
        for source in sources.values { backend.dispose(endpointID: source.endpointID) }
    }

    func endpointStatus(for port: MIDIOutputPort) -> EndpointStatus {
        endpointStatuses[port] ?? EndpointStatus(
            port: port,
            name: port.midiSourceName,
            endpointID: nil,
            isAvailable: false,
            error: "MIDI endpoint has not been initialized."
        )
    }

    func endpointStatus() -> [MIDIOutputPort: EndpointStatus] { endpointStatuses }

    func setMonitorSink(_ sink: (@Sendable (MonitorEvent) -> Void)?) {
        monitorSink = sink
    }

    func sendButton(_ mapping: MIDIButtonMapping, origin: Origin) -> Result<StateResult, ServiceError> {
        guard let outputMapping = Self.outputMapping(from: mapping) else {
            return .failure(.backend("MIDI button mapping contains a value outside the MIDI 1.0 range."))
        }
        return sendButton(outputMapping, origin: origin)
    }

    private func sendButton(_ mapping: MIDIOutputButtonMapping, origin: Origin) -> Result<StateResult, ServiceError> {
        guard pressedOrigins.insert(origin).inserted else { return .success(.ignored) }
        guard !isDisposed else {
            pressedOrigins.remove(origin)
            return .failure(.backend("MIDI output is shut down."))
        }
        guard (1...16).contains(mapping.channel) else {
            pressedOrigins.remove(origin)
            return .failure(.invalidChannel(mapping.channel))
        }

        let result: Result<StateResult, ServiceError>
        switch mapping.message {
        case let .note(note, velocity, releaseVelocity, behavior):
            result = sendNotes(
                notes: [note], velocity: velocity, releaseVelocity: releaseVelocity,
                behavior: behavior, mapping: mapping, origin: origin
            )
        case let .chord(notes, velocity, releaseVelocity, behavior):
            let uniqueNotes = Array(Set(notes)).sorted()
            guard !uniqueNotes.isEmpty else {
                pressedOrigins.remove(origin)
                return .failure(.backend("Chord must contain at least one note."))
            }
            result = sendNotes(
                notes: uniqueNotes, velocity: velocity, releaseVelocity: releaseVelocity,
                behavior: behavior, mapping: mapping, origin: origin
            )
        case let .controlChange(controller, onValue, offValue, behavior):
            result = sendControlChange(
                mapping: mapping, controller: controller, onValue: onValue,
                offValue: offValue, behavior: behavior, origin: origin
            )
        case let .programChange(program):
            result = emit(
                port: mapping.output,
                word: Self.encodeProgramChange(channel: mapping.channel, program: program),
                summary: "PC \(program) · Ch \(mapping.channel)"
            ).map { _ in StateResult.emitted }
        case .noAction:
            result = .success(.ignored)
        }
        if case .failure = result { pressedOrigins.remove(origin) }
        return result
    }

    func release(origin: Origin) -> Result<StateResult, ServiceError> {
        release(origin: origin, force: false)
    }

    private func release(origin: Origin, force: Bool) -> Result<StateResult, ServiceError> {
        pressedOrigins.remove(origin)
        let notes = activeNotes.filter { $0.origin == origin && (force || $0.releaseOnPhysicalRelease) }.sorted {
            ($0.port.rawValue, $0.channel, $0.note) < ($1.port.rawValue, $1.channel, $1.note)
        }
        let controls = activeControls.filter { $0.origin == origin }.sorted {
            ($0.port.rawValue, $0.channel, $0.controller) < ($1.port.rawValue, $1.channel, $1.controller)
        }
        var emitted = false
        var firstError: ServiceError?

        for active in notes {
            switch emit(
                port: active.port,
                word: Self.encodeNoteOff(channel: active.channel, note: active.note, velocity: active.releaseVelocity),
                summary: "Note Off \(active.note) · Ch \(active.channel)"
            ) {
            case .success:
                activeNotes.remove(active)
                emitted = true
            case let .failure(error):
                firstError = firstError ?? error
            }
        }

        for active in controls {
            // The off value is already emitted for a momentary CC only when
            // the mapping's release arrives; this state entry prevents a
            // duplicate release if the HID stream repeats it.
            if case .success = emit(
                port: active.port,
                word: Self.encodeControlChange(channel: active.channel, controller: active.controller, value: active.offValue),
                summary: "CC \(active.controller) · Ch \(active.channel) · \(active.offValue)"
            ) {
                activeControls.remove(active)
                emitted = true
            } else {
                firstError = firstError ?? .endpointUnavailable(active.port)
            }
        }

        if force || origin.layer == 2 {
            toggleStates = toggleStates.filter { !$0.hasSuffix(":\(origin.identifier):\(origin.layer)") }
        }
        if let firstError { return .failure(firstError) }
        return .success(emitted ? .emitted : .ignored)
    }

    /// Release every active note/control in one layer.  This is used by Fn
    /// release, profile replacement, and import/disconnect cleanup.
    func releaseLayer(_ layer: Int) -> Result<StateResult, ServiceError> {
        let origins = Set(activeNotes.map(\ .origin).filter { $0.layer == layer })
            .union(Set(activeControls.map(\ .origin).filter { $0.layer == layer }))
            .union(Set(pressedOrigins.filter { $0.layer == layer }))
        var failed: ServiceError?
        var emitted = false
        for origin in origins.sorted(by: { ($0.layer, $0.identifier) < ($1.layer, $1.identifier) }) {
            switch release(origin: origin, force: true) {
            case .success(.emitted): emitted = true
            case let .failure(error): failed = failed ?? error
            case .success: break
            }
        }
        if let failed { return .failure(failed) }
        return .success(emitted ? .emitted : .ignored)
    }

    /// Defensive cleanup sends All Notes Off (CC 123) on every channel that
    /// carried live state, after matching individual Note Off messages.
    func panic() -> Result<StateResult, ServiceError> {
        var channels = Set(activeNotes.map { ActiveChannel(port: $0.port, channel: $0.channel) })
        channels.formUnion(activeControls.map { ActiveChannel(port: $0.port, channel: $0.channel) })
        let releaseResult = releaseAllTrackedNotesAndControls()
        var failed: ServiceError?
        var emitted = false
        var silencedChannels: Set<ActiveChannel> = []
        for channelKey in channels.sorted(by: { ($0.port.rawValue, $0.channel) < ($1.port.rawValue, $1.channel) }) {
            let port = channelKey.port
            let channel = channelKey.channel
            switch emit(
                port: port,
                word: Self.encodeControlChange(channel: channel, controller: 123, value: 0),
                summary: "All Notes Off · Ch \(channel)"
            ) {
            case .success:
                emitted = true
                silencedChannels.insert(channelKey)
            case let .failure(error):
                failed = failed ?? error
            }
        }

        // A successful All Notes Off is authoritative only for notes on that
        // port/channel. It does not restore arbitrary CC parameters to each
        // mapping's off value, so failed momentary controls remain retryable.
        for channel in silencedChannels {
            activeNotes = activeNotes.filter { !($0.port == channel.port && $0.channel == channel.channel) }
        }
        if case let .failure(releaseError) = releaseResult,
           !activeNotes.isEmpty || !activeControls.isEmpty || silencedChannels.count < channels.count {
            failed = failed ?? releaseError
        }

        let wheelResult = resetWheelState()
        failed = failed ?? wheelResult.error
        emitted = emitted || wheelResult.emitted
        pressedOrigins.removeAll()
        toggleStates.removeAll()
        if let failed { return .failure(failed) }
        return .success(emitted ? .emitted : .ignored)
    }

    func resetForProfileChange() -> Result<StateResult, ServiceError> {
        panic()
    }

    func resetForImport() -> Result<StateResult, ServiceError> {
        resetForProfileChange()
    }

    func resetForDisconnect() -> Result<StateResult, ServiceError> {
        resetForProfileChange()
    }

    func resetForShutdown() -> Result<StateResult, ServiceError> {
        let result = panic()
        isDisposed = true
        for source in sources.values { backend.dispose(endpointID: source.endpointID) }
        sources.removeAll()
        return result
    }

    func wheel(_ direction: MIDIWheelDirection, mapping: MIDIWheelMapping) -> Result<StateResult, ServiceError> {
        guard let outputMapping = Self.outputMapping(from: mapping) else {
            return .failure(.backend("MIDI wheel mapping contains a value outside the MIDI 1.0 range."))
        }
        return wheel(direction, mapping: outputMapping)
    }

    private func wheel(_ direction: MIDIWheelDirection, mapping: MIDIOutputWheelMapping) -> Result<StateResult, ServiceError> {
        switch mapping {
        case let .relativeCC(output, channel, controller, clockwise, counterClockwise, _):
            guard (1...16).contains(channel) else { return .failure(.invalidChannel(channel)) }
            let value = direction == .clockwise ? clockwise : counterClockwise
            return emit(
                port: output,
                word: Self.encodeControlChange(channel: channel, controller: controller, value: value),
                summary: "CC \(controller) · Ch \(channel) · \(value)"
            ).map { _ in StateResult.emitted }
        case let .absoluteCC(output, channel, controller, initialValue, step, reversed):
            guard (1...16).contains(channel) else { return .failure(.invalidChannel(channel)) }
            let key = WheelKey(port: output, channel: channel, kind: "absolute", number: controller)
            let current = Int(absoluteWheelValues[key] ?? initialValue)
            let effectiveDirection = reversed ? direction.opposite : direction
            let delta = effectiveDirection == .clockwise ? Int(step) : -Int(step)
            let next = UInt8(max(0, min(127, current + delta)))
            absoluteWheelValues[key] = next
            return emit(
                port: output,
                word: Self.encodeControlChange(channel: channel, controller: controller, value: next),
                summary: "CC \(controller) · Ch \(channel) · \(next)"
            ).map { _ in StateResult.emitted }
        case let .pitchBend(output, channel, step, delay, duration, reversed):
            guard (1...16).contains(channel) else { return .failure(.invalidChannel(channel)) }
            let key = WheelKey(port: output, channel: channel, kind: "pitch", number: 0)
            let current = Int(pitchBendValues[key] ?? 8192)
            let effectiveDirection = reversed ? direction.opposite : direction
            let delta = effectiveDirection == .clockwise ? Int(step) : -Int(step)
            let next = UInt16(max(0, min(16383, current + delta)))
            pitchBendValues[key] = next
            pitchGenerations[key, default: 0] &+= 1
            pitchReturnTasks[key]?.cancel()
            let generation = pitchGenerations[key] ?? 0
            let initial = next
            let result = emit(
                port: output,
                word: Self.encodePitchBend(channel: channel, value: next),
                summary: "Pitch Bend \(next) · Ch \(channel)"
            ).map { _ in StateResult.emitted }
            pitchReturnTasks[key] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    let steps = max(1, Int(ceil(max(0, duration) / 0.01)))
                    for index in 1...steps {
                        try Task.checkCancellation()
                        if duration > 0 {
                            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000 / Double(steps)))
                        }
                        await self?.finishPitchReturn(
                            key: key, output: output, channel: channel,
                            from: initial, index: index, steps: steps, generation: generation
                        )
                    }
                } catch { }
            }
            return result
        case .transpose, .drumBank:
            return .success(.stateUpdated)
        case .noAction:
            return .success(.ignored)
        }
    }

    func resetPitchBend() {
        _ = resetPitchBendState()
    }

    private func resetPitchBendState() -> (error: ServiceError?, emitted: Bool) {
        var firstError: ServiceError?
        var emitted = false
        for (key, value) in pitchBendValues {
            pitchReturnTasks[key]?.cancel()
            pitchGenerations[key, default: 0] &+= 1
            guard value != 8192 else { continue }
            switch emit(
                port: key.port,
                word: Self.encodePitchBend(channel: key.channel, value: 8192),
                summary: "Pitch Bend 8192 · Ch \(key.channel)"
            ) {
            case .success:
                pitchBendValues[key] = 8192
                emitted = true
            case let .failure(error):
                firstError = firstError ?? error
            }
        }
        return (firstError, emitted)
    }

    private func resetWheelState() -> (error: ServiceError?, emitted: Bool) {
        absoluteWheelValues.removeAll()
        return resetPitchBendState()
    }

    func resetWheels() {
        _ = resetWheelState()
    }

    func activeNoteCount() -> Int { activeNotes.count }
    func activeControlCount() -> Int { activeControls.count }

    func activeNotesForTesting() -> Set<String> {
        Set(activeNotes.map { "\($0.port.rawValue):\($0.channel):\($0.note):\($0.origin.identifier):\($0.origin.layer)" })
    }

    private static func outputMapping(from mapping: MIDIButtonMapping) -> MIDIOutputButtonMapping? {
        guard let channel = UInt8(exactly: mapping.channel), (1...16).contains(channel) else { return nil }
        guard let behavior = MIDIOutputButtonBehavior(rawValue: mapping.interaction.rawValue) else { return nil }
        switch mapping.kind {
        case .note:
            guard let note = UInt8(exactly: mapping.note), let velocity = UInt8(exactly: mapping.velocity),
                  let releaseVelocity = UInt8(exactly: mapping.releaseVelocity),
                  [note, velocity, releaseVelocity].allSatisfy({ $0 <= 127 }) else { return nil }
            return MIDIOutputButtonMapping(
                output: mapping.outputPort, channel: channel,
                message: .note(note: note, velocity: velocity, releaseVelocity: releaseVelocity, behavior: behavior)
            )
        case .chord:
            guard !mapping.chord.isEmpty,
                  let notes = Optional(mapping.chord.compactMap(UInt8.init(exactly:))),
                  notes.count == mapping.chord.count,
                  let velocity = UInt8(exactly: mapping.velocity), let releaseVelocity = UInt8(exactly: mapping.releaseVelocity),
                  notes.allSatisfy({ $0 <= 127 }), velocity <= 127, releaseVelocity <= 127 else { return nil }
            return MIDIOutputButtonMapping(
                output: mapping.outputPort, channel: channel,
                message: .chord(notes: notes, velocity: velocity, releaseVelocity: releaseVelocity, behavior: behavior)
            )
        case .cc:
            guard let controller = UInt8(exactly: mapping.controller), let onValue = UInt8(exactly: mapping.pressValue),
                  let offValue = UInt8(exactly: mapping.releaseValue), [controller, onValue, offValue].allSatisfy({ $0 <= 127 }) else { return nil }
            return MIDIOutputButtonMapping(
                output: mapping.outputPort, channel: channel,
                message: .controlChange(controller: controller, onValue: onValue, offValue: offValue, behavior: behavior)
            )
        case .program:
            guard let program = UInt8(exactly: mapping.program), program <= 127 else { return nil }
            return MIDIOutputButtonMapping(output: mapping.outputPort, channel: channel, message: .programChange(program: program))
        case .noAction:
            return MIDIOutputButtonMapping(output: mapping.outputPort, channel: channel, message: .noAction)
        }
    }

    private static func outputMapping(from mapping: MIDIWheelMapping) -> MIDIOutputWheelMapping? {
        guard let channel = UInt8(exactly: mapping.channel), (1...16).contains(channel),
              let controller = UInt8(exactly: mapping.controller), controller <= 127 else { return nil }
        switch mapping.kind {
        case .relativeCC:
            guard let clockwise = UInt8(exactly: mapping.clockwiseValue), let counterClockwise = UInt8(exactly: mapping.counterClockwiseValue),
                  clockwise <= 127, counterClockwise <= 127 else { return nil }
            let values = mapping.reversedDirection ? (counterClockwise, clockwise) : (clockwise, counterClockwise)
            return .relativeCC(output: mapping.outputPort, channel: channel, controller: controller,
                               clockwiseValue: values.0, counterClockwiseValue: values.1, encoding: mapping.relativeEncoding)
        case .absoluteCC:
            guard let step = Int16(exactly: mapping.stepSize), (1...127).contains(step) else { return nil }
            return .absoluteCC(
                output: mapping.outputPort, channel: channel, controller: controller,
                initialValue: 64, step: step, reversed: mapping.reversedDirection
            )
        case .pitchBendNudgeReturn:
            guard let step = UInt16(exactly: mapping.pitchBendStep), (1...8192).contains(step) else { return nil }
            return .pitchBend(
                output: mapping.outputPort, channel: channel, step: step,
                returnDelay: mapping.returnDelay, returnDuration: mapping.returnDuration,
                reversed: mapping.reversedDirection
            )
        case .transpose:
            return .transpose
        case .drumBank:
            return .drumBank
        case .noAction:
            return .noAction
        }
    }

    static func encodeNoteOn(channel: UInt8, note: UInt8, velocity: UInt8, group: UInt8 = 0) -> UInt32 {
        encodeChannelVoice(status: 0x90, channel: channel, data1: note, data2: velocity, group: group)
    }

    static func encodeNoteOff(channel: UInt8, note: UInt8, velocity: UInt8, group: UInt8 = 0) -> UInt32 {
        encodeChannelVoice(status: 0x80, channel: channel, data1: note, data2: velocity, group: group)
    }

    static func encodeControlChange(channel: UInt8, controller: UInt8, value: UInt8, group: UInt8 = 0) -> UInt32 {
        encodeChannelVoice(status: 0xB0, channel: channel, data1: controller, data2: value, group: group)
    }

    static func encodeProgramChange(channel: UInt8, program: UInt8, group: UInt8 = 0) -> UInt32 {
        ((UInt32(0x2) << 28) | (UInt32(group & 0x0F) << 24) |
            (UInt32(0xC0 | channelIndex(channel)) << 16) | (UInt32(program) << 8))
    }

    static func encodePitchBend(channel: UInt8, value: UInt16, group: UInt8 = 0) -> UInt32 {
        let clamped = min(value, 16383)
        return encodeChannelVoice(
            status: 0xE0,
            channel: channel,
            data1: UInt8(clamped & 0x7F),
            data2: UInt8((clamped >> 7) & 0x7F),
            group: group
        )
    }

    private static func encodeChannelVoice(
        status: UInt8,
        channel: UInt8,
        data1: UInt8,
        data2: UInt8,
        group: UInt8
    ) -> UInt32 {
        let channelIndex = channelIndex(channel)
        return (UInt32(0x2) << 28) | (UInt32(group & 0x0F) << 24) |
            (UInt32(status | channelIndex) << 16) |
            (UInt32(data1 & 0x7F) << 8) | UInt32(data2 & 0x7F)
    }

    private static func channelIndex(_ channel: UInt8) -> UInt8 {
        channel == 0 ? 0 : (channel - 1) & 0x0F
    }

    private static func makeSource(
        for port: MIDIOutputPort,
        backend: any MIDIOutputBackend,
        defaults: UserDefaults
    ) -> (source: MIDIBackendSource?, status: EndpointStatus) {
        let key = endpointKey(for: port)
        let preferred = defaults.object(forKey: key) as? NSNumber
        let preferredID = preferred.map { MIDIUniqueID($0.int32Value) }
        do {
            let source = try backend.createSource(name: port.midiSourceName, preferredUniqueID: preferredID)
            defaults.set(Int(source.endpointID), forKey: key)
            return (source, EndpointStatus(
                port: port, name: port.midiSourceName, endpointID: source.endpointID,
                isAvailable: true, error: source.stableIDWarning
            ))
        } catch {
            return (nil, EndpointStatus(
                port: port, name: port.midiSourceName, endpointID: nil,
                isAvailable: false, error: error.localizedDescription
            ))
        }
    }

    private static func endpointKey(for port: MIDIOutputPort) -> String {
        switch port {
        case .control: return Self.controlEndpointDefaultsKey
        case .performance: return Self.performanceEndpointDefaultsKey
        }
    }

    private func sendNotes(
        notes: [UInt8], velocity: UInt8, releaseVelocity: UInt8,
        behavior: MIDIOutputButtonBehavior, mapping: MIDIOutputButtonMapping, origin: Origin
    ) -> Result<StateResult, ServiceError> {
        if behavior == .momentary {
            let activeForOrigin = activeNotes.filter { $0.origin == origin }
            if !activeForOrigin.isEmpty { return .success(.ignored) }
        }

        if behavior == .toggle {
            let stateKey = "note:\(mapping.output.rawValue):\(mapping.channel):\(origin.identifier):\(origin.layer)"
            let isOn = toggleStates.contains(stateKey)
            if isOn {
                var firstError: ServiceError?
                for note in notes {
                    guard activeNotes.contains(where: { $0.port == mapping.output && $0.channel == mapping.channel && $0.note == note && $0.origin == origin }) else { continue }
                    switch emit(
                        port: mapping.output,
                        word: Self.encodeNoteOff(channel: mapping.channel, note: note, velocity: releaseVelocity),
                        summary: "Note Off \(note) · Ch \(mapping.channel)"
                    ) {
                    case .success:
                        activeNotes = activeNotes.filter { active in
                            !(active.port == mapping.output && active.channel == mapping.channel &&
                              active.note == note && active.origin == origin)
                        }
                    case let .failure(error):
                        firstError = firstError ?? error
                    }
                }
                if let firstError { return .failure(firstError) }
                toggleStates.remove(stateKey)
                return .success(.emitted)
            }
        }

        var emitted = false
        for note in notes {
            let active = ActiveNote(
                port: mapping.output, channel: mapping.channel, note: note,
                origin: origin, releaseVelocity: releaseVelocity,
                releaseOnPhysicalRelease: behavior == .momentary
            )
            guard !activeNotes.contains(active) else { continue }
            switch emit(
                port: mapping.output,
                word: Self.encodeNoteOn(channel: mapping.channel, note: note, velocity: velocity),
                summary: "Note On \(note) · Ch \(mapping.channel) · V\(velocity)"
            ) {
            case .success:
                emitted = true
                if behavior == .oneShot {
                    switch emit(
                        port: mapping.output,
                        word: Self.encodeNoteOff(channel: mapping.channel, note: note, velocity: releaseVelocity),
                        summary: "Note Off \(note) · Ch \(mapping.channel)"
                    ) {
                    case .success:
                        break
                    case let .failure(error):
                        // Keep the note tracked for a later panic/release
                        // retry if the matching off cannot be delivered now.
                        activeNotes.insert(ActiveNote(
                            port: active.port, channel: active.channel, note: active.note,
                            origin: active.origin, releaseVelocity: active.releaseVelocity,
                            releaseOnPhysicalRelease: true
                        ))
                        return .failure(error)
                    }
                } else {
                    activeNotes.insert(active)
                }
            case let .failure(error):
                return .failure(error)
            }
        }
        if behavior == .toggle, emitted {
            let stateKey = "note:\(mapping.output.rawValue):\(mapping.channel):\(origin.identifier):\(origin.layer)"
            toggleStates.insert(stateKey)
        }
        return .success(emitted ? .emitted : .ignored)
    }

    private func sendControlChange(
        mapping: MIDIOutputButtonMapping, controller: UInt8, onValue: UInt8,
        offValue: UInt8, behavior: MIDIOutputButtonBehavior, origin: Origin
    ) -> Result<StateResult, ServiceError> {
        let active = ActiveControl(port: mapping.output, channel: mapping.channel, controller: controller, offValue: offValue, origin: origin)
        if behavior == .momentary {
            guard !activeControls.contains(active) else { return .success(.ignored) }
            activeControls.insert(active)
            let result = emit(
                port: mapping.output,
                word: Self.encodeControlChange(channel: mapping.channel, controller: controller, value: onValue),
                summary: "CC \(controller) · Ch \(mapping.channel) · \(onValue)"
            ).map { _ in StateResult.emitted }
            if case .failure = result { activeControls.remove(active) }
            return result
        }
        let stateKey = "cc:\(mapping.output.rawValue):\(mapping.channel):\(controller):\(origin.identifier):\(origin.layer)"
        if behavior == .toggle {
            let isOn = toggleStates.contains(stateKey)
            let value = isOn ? offValue : onValue
            let result = emit(
                port: mapping.output,
                word: Self.encodeControlChange(channel: mapping.channel, controller: controller, value: value),
                summary: "CC \(controller) · Ch \(mapping.channel) · \(value)"
            ).map { _ in StateResult.emitted }
            if case .success = result {
                if isOn { toggleStates.remove(stateKey) } else { toggleStates.insert(stateKey) }
            }
            return result
        }
        return emit(
            port: mapping.output,
            word: Self.encodeControlChange(channel: mapping.channel, controller: controller, value: onValue),
            summary: "CC \(controller) · Ch \(mapping.channel) · \(onValue)"
        ).map { _ in StateResult.emitted }
    }

    private func emit(port: MIDIOutputPort, word: UInt32, summary: String) -> Result<StateResult, ServiceError> {
        guard let source = sources[port], endpointStatuses[port]?.isAvailable == true else {
            let error = ServiceError.endpointUnavailable(port)
            lastError = error.localizedDescription
            recordMonitorEvent(port: port, word: word, summary: summary, outcome: .failed, error: error.localizedDescription)
            return .failure(error)
        }
        do {
            try backend.send(words: [word], to: source.endpointID)
            lastMessage = SentMessage(port: port, word: word, summary: summary)
            lastError = nil
            recordMonitorEvent(port: port, word: word, summary: summary, outcome: .sent, error: nil)
            return .success(.emitted)
        } catch {
            lastError = error.localizedDescription
            recordMonitorEvent(port: port, word: word, summary: summary, outcome: .failed, error: error.localizedDescription)
            return .failure(.backend(error.localizedDescription))
        }
    }

    private func recordMonitorEvent(
        port: MIDIOutputPort,
        word: UInt32,
        summary: String,
        outcome: MonitorEvent.Outcome,
        error: String?
    ) {
        monitorSequence &+= 1
        monitorSink?(MonitorEvent(
            sequence: monitorSequence,
            timestamp: Date(),
            port: port,
            word: word,
            summary: summary,
            outcome: outcome,
            error: error
        ))
    }

    private func releaseAllTrackedNotesAndControls() -> Result<StateResult, ServiceError> {
        let origins = Set(activeNotes.map(\ .origin)).union(Set(activeControls.map(\ .origin)))
        var failed: ServiceError?
        var emitted = false
        for origin in origins.sorted(by: { ($0.layer, $0.identifier) < ($1.layer, $1.identifier) }) {
            switch release(origin: origin, force: true) {
            case .success(.emitted): emitted = true
            case let .failure(error): failed = failed ?? error
            case .success: break
            }
        }
        if let failed { return .failure(failed) }
        return .success(emitted ? .emitted : .ignored)
    }

    private func finishPitchReturn(
        key: WheelKey, output: MIDIOutputPort, channel: UInt8,
        from: UInt16, index: Int, steps: Int, generation: UInt64
    ) {
        guard pitchGenerations[key] == generation else { return }
        let next = UInt16(Int(from) + ((8192 - Int(from)) * index / steps))
        pitchBendValues[key] = next
        _ = emit(
            port: output,
            word: Self.encodePitchBend(channel: channel, value: next),
            summary: "Pitch Bend \(next) · Ch \(channel)"
        )
        if index == steps { pitchReturnTasks[key] = nil }
    }
}

private final class UnavailableMIDIOutputBackend: MIDIOutputBackend, @unchecked Sendable {
    func createSource(name: String, preferredUniqueID: MIDIUniqueID?) throws -> MIDIBackendSource {
        throw MIDIOutputService.ServiceError.backend("CoreMIDI is unavailable.")
    }

    func send(words: [UInt32], to endpointID: MIDIUniqueID) throws {
        throw MIDIOutputService.ServiceError.backend("CoreMIDI is unavailable.")
    }

    func dispose(endpointID: MIDIUniqueID) { }
}

private final class CoreMIDIOutputBackend: MIDIOutputBackend, @unchecked Sendable {
    private var client: MIDIClientRef = 0
    private var endpoints: [MIDIUniqueID: MIDIEndpointRef] = [:]

    init() throws {
        let status = MIDIClientCreateWithBlock("XP[d] MIDI Output" as CFString, &client, nil)
        guard status == noErr else { throw MIDIOutputService.ServiceError.backend("MIDI client creation failed (\(status)).") }
    }

    deinit {
        if client != 0 { MIDIClientDispose(client) }
    }

    func createSource(name: String, preferredUniqueID: MIDIUniqueID?) throws -> MIDIBackendSource {
        var endpoint: MIDIEndpointRef = 0
        let status = MIDISourceCreateWithProtocol(client, name as CFString, MIDIProtocolID(rawValue: 1)!, &endpoint)
        guard status == noErr else { throw MIDIOutputService.ServiceError.backend("\(name) endpoint creation failed (\(status)).") }

        var endpointID: MIDIUniqueID = 0
        let readStatus = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &endpointID)
        guard readStatus == noErr, endpointID != 0 else {
            MIDIEndpointDispose(endpoint)
            throw MIDIOutputService.ServiceError.backend("\(name) endpoint ID query failed (\(readStatus)).")
        }

        var warning: String?
        if let preferredUniqueID, preferredUniqueID != 0, preferredUniqueID != endpointID {
            let setStatus = MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, preferredUniqueID)
            if setStatus == noErr {
                endpointID = preferredUniqueID
            } else {
                warning = "\(name) created, but its saved endpoint ID could not be restored (\(setStatus))."
            }
        }
        endpoints[endpointID] = endpoint
        return MIDIBackendSource(endpointID: endpointID, stableIDWarning: warning)
    }

    func send(words: [UInt32], to endpointID: MIDIUniqueID) throws {
        guard let endpoint = endpoints[endpointID] else {
            throw MIDIOutputService.ServiceError.backend("Unknown MIDI endpoint \(endpointID).")
        }
        let capacity = max(256, MemoryLayout<MIDIEventList>.size + words.count * MemoryLayout<UInt32>.size + 32)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { storage.deallocate() }
        let eventList = storage.assumingMemoryBound(to: MIDIEventList.self)
        let firstPacket = MIDIEventListInit(eventList, MIDIProtocolID(rawValue: 1)!)
        let timestamp = mach_absolute_time()
        _ = words.withUnsafeBufferPointer { buffer in
            MIDIEventListAdd(
                eventList,
                capacity,
                firstPacket,
                timestamp,
                words.count,
                buffer.baseAddress!
            )
        }
        let status = MIDIReceivedEventList(endpoint, eventList)
        guard status == noErr else { throw MIDIOutputService.ServiceError.backend("MIDI send failed (\(status)).") }
    }

    func dispose(endpointID: MIDIUniqueID) {
        if let endpoint = endpoints.removeValue(forKey: endpointID) { MIDIEndpointDispose(endpoint) }
    }
}
