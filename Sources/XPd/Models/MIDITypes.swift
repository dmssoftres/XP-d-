import Foundation

/// The two kinds of profiles XP[d] can host.  A profile's realm is persisted
/// explicitly; it is never inferred from the profile's display name.
enum ProfileRealm: String, Codable, CaseIterable, Identifiable, Hashable {
    case standard
    case midi

    var id: String { rawValue }
}

/// The stable virtual MIDI source selected by an individual mapping.
enum MIDIOutputPort: String, Codable, CaseIterable, Identifiable, Hashable {
    case control
    case performance

    var id: String { rawValue }

    var midiSourceName: String {
        switch self {
        case .control: return "XP[d] Control"
        case .performance: return "XP[d] Performance"
        }
    }

    var displayName: String { midiSourceName }
}

/// A MIDI profile has one ordinary layer and one momentary Fn layer.
enum MIDIMappingLayer: String, Codable, CaseIterable, Identifiable, Hashable {
    case primary
    case function

    var id: String { rawValue }
}

/// The typed messages supported by the first MIDI profile implementation.
enum MIDIButtonKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case note = "Note"
    case cc = "CC"
    case program = "Program"
    case chord = "Chord"
    case noAction = "No action"

    var id: String { rawValue }
}

/// Compatibility spelling for callers that use “message” instead of “kind”.
typealias MIDIButtonMessageKind = MIDIButtonKind
typealias MIDIButtonMessageType = MIDIButtonKind
typealias MIDIButtonType = MIDIButtonKind

/// How a button mapping behaves after its physical press.
enum MIDIButtonInteraction: String, Codable, CaseIterable, Identifiable, Hashable {
    case momentary
    case toggle
    case oneShot

    var id: String { rawValue }
}

typealias MIDIButtonInteractionKind = MIDIButtonInteraction
typealias MIDIButtonBehavior = MIDIButtonInteraction

/// Typed wheel messages.  A directional wheel does not expose an absolute
/// position, so pitch bend and transpose are stateful services layered above
/// these values.
enum MIDIWheelKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case relativeCC = "Relative CC"
    case absoluteCC = "Absolute CC"
    case pitchBendNudgeReturn = "Pitch Bend — Nudge and Return"
    case transpose = "Transpose"
    case drumBank = "Drum Bank"
    case noAction = "No action"

    var id: String { rawValue }
}

typealias MIDIWheelMappingKind = MIDIWheelKind

/// Relative-controller encodings understood by common DAWs.
enum MIDIRelativeEncoding: String, Codable, CaseIterable, Identifiable, Hashable {
    case twosComplement = "Two's Complement"
    case binaryOffset = "Binary Offset"
    case signedBit = "Signed Bit"

    var id: String { rawValue }

    // Alternate spellings keep the model pleasant to use from future UI and
    // service code while retaining one canonical Codable representation.
    static var twoComplement: Self { .twosComplement }
    static var signBit: Self { .signedBit }
}

typealias MIDIWheelRelativeEncoding = MIDIRelativeEncoding

enum MIDIValidationError: LocalizedError, Equatable {
    case invalidChannel(Int)
    case invalidMIDIValue(field: String, value: Int)
    case invalidChord(String)
    case invalidChordSize(Int)
    case invalidLabel
    case invalidButtonControl(RemoteControl)
    case invalidFnControl(RemoteControl)
    case invalidFnHoldThreshold(Double)
    case duplicateButtonMapping(layer: MIDIMappingLayer, control: RemoteControl)
    case invalidPitchRange(Int)
    case invalidPitchBendStep(Int)
    case invalidReturnTiming(field: String, value: Double)
    case invalidTranspose(Int)
    case invalidDrumBankStep(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidChannel(channel):
            return "MIDI channels must be in the range 1...16: \(channel)."
        case let .invalidMIDIValue(field, value):
            return "MIDI \(field) must be in the range 0...127: \(value)."
        case let .invalidChord(reason):
            return "Invalid MIDI chord: \(reason)."
        case let .invalidChordSize(size):
            return "MIDI chords must contain 1...16 notes: \(size)."
        case .invalidLabel:
            return "MIDI labels must be trimmed and at most 80 characters."
        case let .invalidButtonControl(control):
            return "\(control.rawValue) is not a MIDI button control."
        case let .invalidFnControl(control):
            return "\(control.rawValue) cannot be assigned as the Fn control."
        case let .invalidFnHoldThreshold(threshold):
            return "Fn hold threshold must be finite and in the range 0.10...3.0 seconds: \(threshold)."
        case let .duplicateButtonMapping(layer, control):
            return "Duplicate \(layer.rawValue) MIDI mapping for \(control.rawValue)."
        case let .invalidPitchRange(range):
            return "Pitch-bend ranges must be in the range 1...96 semitones: \(range)."
        case let .invalidPitchBendStep(step):
            return "Pitch-bend steps must be in the range 1...8192: \(step)."
        case let .invalidReturnTiming(field, value):
            return "MIDI \(field) must be between 0 and 60 seconds: \(value)."
        case let .invalidTranspose(value):
            return "Transpose must be in the range -127...127 semitones: \(value)."
        case let .invalidDrumBankStep(value):
            return "Drum-bank steps must be in the range 1...127: \(value)."
        }
    }
}

/// A typed MIDI mapping for one K button.  All message-specific values are
/// explicit fields so editors can change them without parsing a free-form
/// command string.  Unused fields retain safe defaults and are still validated
/// on import so malformed documents cannot hide invalid data.
struct MIDIButtonMapping: Codable, Equatable {
    static let maxChordNotes = 16

    var kind: MIDIButtonKind
    var outputPort: MIDIOutputPort
    /// Displayed and persisted as the conventional 1...16 MIDI channel.
    var channel: Int
    var note: Int
    var controller: Int
    var program: Int
    var value: Int
    var pressValue: Int
    var releaseValue: Int
    var velocity: Int
    var releaseVelocity: Int
    var chord: [Int]
    var interaction: MIDIButtonInteraction
    var label: String

    var messageType: MIDIButtonKind {
        get { kind }
        set { kind = newValue }
    }

    var buttonKind: MIDIButtonKind {
        get { kind }
        set { kind = newValue }
    }

    var output: MIDIOutputPort {
        get { outputPort }
        set { outputPort = newValue }
    }

    var behavior: MIDIButtonInteraction {
        get { interaction }
        set { interaction = newValue }
    }

    var type: MIDIButtonKind {
        get { kind }
        set { kind = newValue }
    }

    var cc: Int {
        get { controller }
        set { controller = newValue }
    }

    var controllerNumber: Int {
        get { controller }
        set { controller = newValue }
    }

    var programNumber: Int {
        get { program }
        set { program = newValue }
    }

    var chordNotes: [Int] {
        get { chord }
        set { chord = newValue }
    }

    var notes: [Int] {
        get { chord }
        set { chord = newValue }
    }

    init(
        kind: MIDIButtonKind = .noAction,
        outputPort: MIDIOutputPort = .performance,
        channel: Int = 1,
        note: Int = 60,
        controller: Int = 1,
        program: Int = 0,
        value: Int = 127,
        pressValue: Int = 127,
        releaseValue: Int = 0,
        velocity: Int = 100,
        releaseVelocity: Int = 0,
        chord: [Int] = [60, 64, 67],
        interaction: MIDIButtonInteraction = .momentary,
        label: String = ""
    ) {
        self.kind = kind
        self.outputPort = outputPort
        self.channel = channel
        self.note = note
        self.controller = controller
        self.program = program
        self.value = value
        self.pressValue = pressValue
        self.releaseValue = releaseValue
        self.velocity = velocity
        self.releaseVelocity = releaseVelocity
        self.chord = chord
        self.interaction = interaction
        self.label = label
    }

    init(
        messageType: MIDIButtonKind,
        outputPort: MIDIOutputPort = .performance,
        channel: Int = 1,
        note: Int = 60,
        controller: Int = 1,
        program: Int = 0,
        value: Int = 127,
        pressValue: Int = 127,
        releaseValue: Int = 0,
        velocity: Int = 100,
        releaseVelocity: Int = 0,
        chord: [Int] = [60, 64, 67],
        interaction: MIDIButtonInteraction = .momentary,
        label: String = ""
    ) {
        self.init(
            kind: messageType,
            outputPort: outputPort,
            channel: channel,
            note: note,
            controller: controller,
            program: program,
            value: value,
            pressValue: pressValue,
            releaseValue: releaseValue,
            velocity: velocity,
            releaseVelocity: releaseVelocity,
            chord: chord,
            interaction: interaction,
            label: label
        )
    }

    /// Chord-oriented overload with the chord value next to its message kind;
    /// this keeps call sites readable while preserving the fully explicit
    /// initializer above for editors and migration code.
    init(
        kind: MIDIButtonKind,
        outputPort: MIDIOutputPort = .performance,
        channel: Int = 1,
        chord: [Int],
        velocity: Int = 100,
        releaseVelocity: Int = 0,
        interaction: MIDIButtonInteraction = .momentary,
        label: String = ""
    ) {
        self.init(
            kind: kind,
            outputPort: outputPort,
            channel: channel,
            velocity: velocity,
            releaseVelocity: releaseVelocity,
            chord: chord,
            interaction: interaction,
            label: label
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(MIDIButtonKind.self, forKey: .kind)
            ?? container.decodeIfPresent(MIDIButtonKind.self, forKey: .messageType)
            ?? .noAction
        outputPort = try container.decodeIfPresent(MIDIOutputPort.self, forKey: .outputPort) ?? .performance
        channel = try container.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        note = try container.decodeIfPresent(Int.self, forKey: .note) ?? 60
        controller = try container.decodeIfPresent(Int.self, forKey: .controller)
            ?? container.decodeIfPresent(Int.self, forKey: .cc)
            ?? 1
        program = try container.decodeIfPresent(Int.self, forKey: .program)
            ?? container.decodeIfPresent(Int.self, forKey: .programNumber)
            ?? 0
        value = try container.decodeIfPresent(Int.self, forKey: .value) ?? 127
        pressValue = try container.decodeIfPresent(Int.self, forKey: .pressValue) ?? 127
        releaseValue = try container.decodeIfPresent(Int.self, forKey: .releaseValue) ?? 0
        velocity = try container.decodeIfPresent(Int.self, forKey: .velocity) ?? 100
        releaseVelocity = try container.decodeIfPresent(Int.self, forKey: .releaseVelocity) ?? 0
        chord = try container.decodeIfPresent([Int].self, forKey: .chord)
            ?? container.decodeIfPresent([Int].self, forKey: .chordNotes)
            ?? [60, 64, 67]
        interaction = try container.decodeIfPresent(MIDIButtonInteraction.self, forKey: .interaction) ?? .momentary
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(outputPort, forKey: .outputPort)
        try container.encode(channel, forKey: .channel)
        try container.encode(note, forKey: .note)
        try container.encode(controller, forKey: .controller)
        try container.encode(program, forKey: .program)
        try container.encode(value, forKey: .value)
        try container.encode(pressValue, forKey: .pressValue)
        try container.encode(releaseValue, forKey: .releaseValue)
        try container.encode(velocity, forKey: .velocity)
        try container.encode(releaseVelocity, forKey: .releaseVelocity)
        try container.encode(chord, forKey: .chord)
        try container.encode(interaction, forKey: .interaction)
        try container.encode(label, forKey: .label)
    }

    func validate() throws {
        guard (1...16).contains(channel) else { throw MIDIValidationError.invalidChannel(channel) }
        for (field, value) in [
            ("note", note), ("controller", controller), ("program", program),
            ("value", value), ("pressValue", pressValue), ("releaseValue", releaseValue),
            ("velocity", velocity), ("releaseVelocity", releaseVelocity)
        ] where !(0...127).contains(value) {
            throw MIDIValidationError.invalidMIDIValue(field: field, value: value)
        }
        guard chord.count <= Self.maxChordNotes else {
            throw MIDIValidationError.invalidChordSize(chord.count)
        }
        for chordNote in chord where !(0...127).contains(chordNote) {
            throw MIDIValidationError.invalidMIDIValue(field: "chord note", value: chordNote)
        }
        if kind == .chord {
            guard !chord.isEmpty else { throw MIDIValidationError.invalidChord("the chord cannot be empty") }
            guard Set(chord).count == chord.count else {
                throw MIDIValidationError.invalidChord("notes must be unique")
            }
        }
        guard label.trimmingCharacters(in: .whitespacesAndNewlines) == label, label.count <= 80 else {
            throw MIDIValidationError.invalidLabel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, messageType, outputPort, channel, note, controller, cc, program, programNumber
        case value, pressValue, releaseValue, velocity, releaseVelocity, chord, chordNotes
        case interaction, label
    }
}

/// A typed MIDI mapping for the directional wheel.
struct MIDIWheelMapping: Codable, Equatable {
    var kind: MIDIWheelKind
    var outputPort: MIDIOutputPort
    var channel: Int
    var controller: Int
    var relativeEncoding: MIDIRelativeEncoding
    var clockwiseValue: Int
    var counterClockwiseValue: Int
    var stepSize: Int
    var acceleration: Int
    var reversedDirection: Bool
    var pitchBendStep: Int
    var pitchBendRange: Int
    var returnDelay: TimeInterval
    var returnDuration: TimeInterval
    var resetOnEntry: Bool
    var transposeSemitones: Int
    var drumBankStep: Int
    var label: String

    var wheelType: MIDIWheelKind {
        get { kind }
        set { kind = newValue }
    }

    var type: MIDIWheelKind {
        get { kind }
        set { kind = newValue }
    }

    var output: MIDIOutputPort {
        get { outputPort }
        set { outputPort = newValue }
    }

    var controllerNumber: Int {
        get { controller }
        set { controller = newValue }
    }

    var pitchStep: Int {
        get { pitchBendStep }
        set { pitchBendStep = newValue }
    }

    var returnDelaySeconds: TimeInterval {
        get { returnDelay }
        set { returnDelay = newValue }
    }

    var returnDurationSeconds: TimeInterval {
        get { returnDuration }
        set { returnDuration = newValue }
    }

    init(
        kind: MIDIWheelKind = .noAction,
        outputPort: MIDIOutputPort = .performance,
        channel: Int = 1,
        controller: Int = 1,
        relativeEncoding: MIDIRelativeEncoding = .twosComplement,
        clockwiseValue: Int = 1,
        counterClockwiseValue: Int = 127,
        stepSize: Int = 1,
        acceleration: Int = 0,
        reversedDirection: Bool = false,
        pitchBendStep: Int = 512,
        pitchBendRange: Int = 2,
        returnDelay: TimeInterval = 0.25,
        returnDuration: TimeInterval = 0.20,
        resetOnEntry: Bool = true,
        transposeSemitones: Int = 1,
        drumBankStep: Int = 1,
        label: String = ""
    ) {
        self.kind = kind
        self.outputPort = outputPort
        self.channel = channel
        self.controller = controller
        self.relativeEncoding = relativeEncoding
        self.clockwiseValue = clockwiseValue
        self.counterClockwiseValue = counterClockwiseValue
        self.stepSize = stepSize
        self.acceleration = acceleration
        self.reversedDirection = reversedDirection
        self.pitchBendStep = pitchBendStep
        self.pitchBendRange = pitchBendRange
        self.returnDelay = returnDelay
        self.returnDuration = returnDuration
        self.resetOnEntry = resetOnEntry
        self.transposeSemitones = transposeSemitones
        self.drumBankStep = drumBankStep
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(MIDIWheelKind.self, forKey: .kind)
            ?? container.decodeIfPresent(MIDIWheelKind.self, forKey: .wheelType)
            ?? .noAction
        outputPort = try container.decodeIfPresent(MIDIOutputPort.self, forKey: .outputPort) ?? .performance
        channel = try container.decodeIfPresent(Int.self, forKey: .channel) ?? 1
        controller = try container.decodeIfPresent(Int.self, forKey: .controller)
            ?? container.decodeIfPresent(Int.self, forKey: .controllerNumber)
            ?? 1
        relativeEncoding = try container.decodeIfPresent(MIDIRelativeEncoding.self, forKey: .relativeEncoding) ?? .twosComplement
        clockwiseValue = try container.decodeIfPresent(Int.self, forKey: .clockwiseValue) ?? 1
        counterClockwiseValue = try container.decodeIfPresent(Int.self, forKey: .counterClockwiseValue) ?? 127
        stepSize = try container.decodeIfPresent(Int.self, forKey: .stepSize) ?? 1
        acceleration = try container.decodeIfPresent(Int.self, forKey: .acceleration) ?? 0
        reversedDirection = try container.decodeIfPresent(Bool.self, forKey: .reversedDirection) ?? false
        pitchBendStep = try container.decodeIfPresent(Int.self, forKey: .pitchBendStep)
            ?? container.decodeIfPresent(Int.self, forKey: .pitchStep)
            ?? 512
        pitchBendRange = try container.decodeIfPresent(Int.self, forKey: .pitchBendRange) ?? 2
        returnDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .returnDelay)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .returnDelaySeconds)
            ?? 0.25
        returnDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .returnDuration)
            ?? container.decodeIfPresent(TimeInterval.self, forKey: .returnDurationSeconds)
            ?? 0.20
        resetOnEntry = try container.decodeIfPresent(Bool.self, forKey: .resetOnEntry) ?? true
        transposeSemitones = try container.decodeIfPresent(Int.self, forKey: .transposeSemitones) ?? 1
        drumBankStep = try container.decodeIfPresent(Int.self, forKey: .drumBankStep) ?? 1
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(outputPort, forKey: .outputPort)
        try container.encode(channel, forKey: .channel)
        try container.encode(controller, forKey: .controller)
        try container.encode(relativeEncoding, forKey: .relativeEncoding)
        try container.encode(clockwiseValue, forKey: .clockwiseValue)
        try container.encode(counterClockwiseValue, forKey: .counterClockwiseValue)
        try container.encode(stepSize, forKey: .stepSize)
        try container.encode(acceleration, forKey: .acceleration)
        try container.encode(reversedDirection, forKey: .reversedDirection)
        try container.encode(pitchBendStep, forKey: .pitchBendStep)
        try container.encode(pitchBendRange, forKey: .pitchBendRange)
        try container.encode(returnDelay, forKey: .returnDelay)
        try container.encode(returnDuration, forKey: .returnDuration)
        try container.encode(resetOnEntry, forKey: .resetOnEntry)
        try container.encode(transposeSemitones, forKey: .transposeSemitones)
        try container.encode(drumBankStep, forKey: .drumBankStep)
        try container.encode(label, forKey: .label)
    }

    func validate() throws {
        guard (1...16).contains(channel) else { throw MIDIValidationError.invalidChannel(channel) }
        for (field, value) in [("controller", controller), ("clockwiseValue", clockwiseValue), ("counterClockwiseValue", counterClockwiseValue)]
            where !(0...127).contains(value) {
            throw MIDIValidationError.invalidMIDIValue(field: field, value: value)
        }
        guard (1...127).contains(stepSize) else {
            throw MIDIValidationError.invalidMIDIValue(field: "stepSize", value: stepSize)
        }
        guard acceleration >= 0, acceleration <= 127 else {
            throw MIDIValidationError.invalidMIDIValue(field: "acceleration", value: acceleration)
        }
        guard (1...8192).contains(pitchBendStep) else {
            throw MIDIValidationError.invalidPitchBendStep(pitchBendStep)
        }
        guard (1...96).contains(pitchBendRange) else {
            throw MIDIValidationError.invalidPitchRange(pitchBendRange)
        }
        guard (0...60).contains(returnDelay) else {
            throw MIDIValidationError.invalidReturnTiming(field: "return delay", value: returnDelay)
        }
        guard (0...60).contains(returnDuration) else {
            throw MIDIValidationError.invalidReturnTiming(field: "return duration", value: returnDuration)
        }
        guard (-127...127).contains(transposeSemitones) else {
            throw MIDIValidationError.invalidTranspose(transposeSemitones)
        }
        guard (1...127).contains(drumBankStep) else {
            throw MIDIValidationError.invalidDrumBankStep(drumBankStep)
        }
        guard label.trimmingCharacters(in: .whitespacesAndNewlines) == label, label.count <= 80 else {
            throw MIDIValidationError.invalidLabel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, wheelType, outputPort, channel, controller, controllerNumber
        case relativeEncoding, clockwiseValue, counterClockwiseValue, stepSize, acceleration
        case reversedDirection, pitchBendStep, pitchStep, pitchBendRange
        case returnDelay, returnDelaySeconds, returnDuration, returnDurationSeconds, resetOnEntry
        case transposeSemitones, drumBankStep, label
    }
}

struct MIDIButtonMappingEntry: Codable, Equatable, Identifiable {
    let control: RemoteControl
    var mapping: MIDIButtonMapping

    var id: RemoteControl { control }

    init(control: RemoteControl, mapping: MIDIButtonMapping) {
        self.control = control
        self.mapping = mapping
    }
}

/// Per-profile MIDI state. Arrays deliberately preserve a portable order and
/// allow validation to detect duplicate controls rather than silently losing a
/// value as a JSON dictionary would.
struct MIDIProfileSettings: Codable, Equatable {
    static let defaultFnHoldThreshold: TimeInterval = 0.72
    static let empty = MIDIProfileSettings(primaryButtons: [], functionButtons: [])

    var fnControl: RemoteControl?
    /// Duration, in seconds, required before a center-as-Fn press becomes a
    /// held Fn layer. Older settings omit this key and use the safe default.
    var fnHoldThreshold: TimeInterval
    var primaryButtons: [MIDIButtonMappingEntry]
    var functionButtons: [MIDIButtonMappingEntry]
    var primaryWheel: MIDIWheelMapping
    var functionWheel: MIDIWheelMapping

    var primaryButtonMappings: [MIDIButtonMappingEntry] {
        get { primaryButtons }
        set { primaryButtons = newValue }
    }

    var functionButtonMappings: [MIDIButtonMappingEntry] {
        get { functionButtons }
        set { functionButtons = newValue }
    }

    var primaryWheelMapping: MIDIWheelMapping {
        get { primaryWheel }
        set { primaryWheel = newValue }
    }

    var functionWheelMapping: MIDIWheelMapping {
        get { functionWheel }
        set { functionWheel = newValue }
    }

    var fn: RemoteControl? {
        get { fnControl }
        set { fnControl = newValue }
    }

    init(
        fnControl: RemoteControl? = nil,
        fnHoldThreshold: TimeInterval = MIDIProfileSettings.defaultFnHoldThreshold,
        primaryButtons: [MIDIButtonMappingEntry] = [],
        functionButtons: [MIDIButtonMappingEntry] = [],
        primaryWheel: MIDIWheelMapping = MIDIWheelMapping(),
        functionWheel: MIDIWheelMapping = MIDIWheelMapping(kind: .absoluteCC, controller: 1)
    ) {
        self.fnControl = fnControl
        self.fnHoldThreshold = fnHoldThreshold
        self.primaryButtons = primaryButtons
        self.functionButtons = functionButtons
        self.primaryWheel = primaryWheel
        self.functionWheel = functionWheel
    }

    init(
        fnControl: RemoteControl? = nil,
        fnHoldThreshold: TimeInterval = MIDIProfileSettings.defaultFnHoldThreshold,
        primaryButtonMappings: [MIDIButtonMappingEntry],
        functionButtonMappings: [MIDIButtonMappingEntry] = [],
        primaryWheelMapping: MIDIWheelMapping = MIDIWheelMapping(),
        functionWheelMapping: MIDIWheelMapping = MIDIWheelMapping(kind: .absoluteCC, controller: 1)
    ) {
        self.init(
            fnControl: fnControl,
            fnHoldThreshold: fnHoldThreshold,
            primaryButtons: primaryButtonMappings,
            functionButtons: functionButtonMappings,
            primaryWheel: primaryWheelMapping,
            functionWheel: functionWheelMapping
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fnControl = try container.decodeIfPresent(RemoteControl.self, forKey: .fnControl)
        fnHoldThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .fnHoldThreshold)
            ?? Self.defaultFnHoldThreshold
        primaryButtons = try container.decodeIfPresent([MIDIButtonMappingEntry].self, forKey: .primaryButtons)
            ?? container.decodeIfPresent([MIDIButtonMappingEntry].self, forKey: .primaryButtonMappings)
            ?? []
        functionButtons = try container.decodeIfPresent([MIDIButtonMappingEntry].self, forKey: .functionButtons)
            ?? container.decodeIfPresent([MIDIButtonMappingEntry].self, forKey: .functionButtonMappings)
            ?? []
        primaryWheel = try container.decodeIfPresent(MIDIWheelMapping.self, forKey: .primaryWheel)
            ?? container.decodeIfPresent(MIDIWheelMapping.self, forKey: .primaryWheelMapping)
            ?? MIDIWheelMapping()
        functionWheel = try container.decodeIfPresent(MIDIWheelMapping.self, forKey: .functionWheel)
            ?? container.decodeIfPresent(MIDIWheelMapping.self, forKey: .functionWheelMapping)
            ?? MIDIWheelMapping(kind: .absoluteCC, controller: 1)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(fnControl, forKey: .fnControl)
        try container.encode(fnHoldThreshold, forKey: .fnHoldThreshold)
        try container.encode(primaryButtons, forKey: .primaryButtons)
        try container.encode(functionButtons, forKey: .functionButtons)
        try container.encode(primaryWheel, forKey: .primaryWheel)
        try container.encode(functionWheel, forKey: .functionWheel)
    }

    func validate() throws {
        if let fnControl, !fnControl.isMIDIEligibleFnControl {
            throw MIDIValidationError.invalidFnControl(fnControl)
        }
        guard fnHoldThreshold.isFinite, (0.10...3.0).contains(fnHoldThreshold) else {
            throw MIDIValidationError.invalidFnHoldThreshold(fnHoldThreshold)
        }
        try validateButtons(primaryButtons, layer: .primary)
        try validateButtons(functionButtons, layer: .function)
        try primaryWheel.validate()
        try functionWheel.validate()
    }

    private func validateButtons(_ entries: [MIDIButtonMappingEntry], layer: MIDIMappingLayer) throws {
        var controls = Set<RemoteControl>()
        for entry in entries {
            guard entry.control.isMIDIButton else {
                throw MIDIValidationError.invalidButtonControl(entry.control)
            }
            guard controls.insert(entry.control).inserted else {
                throw MIDIValidationError.duplicateButtonMapping(layer: layer, control: entry.control)
            }
            try entry.mapping.validate()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fnControl, fnHoldThreshold, primaryButtons, functionButtons, primaryWheel, functionWheel
        case primaryButtonMappings, functionButtonMappings, primaryWheelMapping, functionWheelMapping
    }
}

extension RemoteControl {
    var isMIDIButton: Bool {
        switch self {
        case .k1, .k2, .k3, .k4, .k5, .k6, .k7, .k8, .k9, .k10:
            return true
        case .wheelCCW, .wheelCW, .wheelCenter:
            return false
        }
    }

    var isMIDIEligibleFnControl: Bool {
        isMIDIButton || self == .wheelCenter
    }
}

extension MIDIButtonMapping {
    typealias ValidationError = MIDIValidationError
}

extension MIDIWheelMapping {
    typealias ValidationError = MIDIValidationError
}

extension MIDIProfileSettings {
    typealias ValidationError = MIDIValidationError
}
