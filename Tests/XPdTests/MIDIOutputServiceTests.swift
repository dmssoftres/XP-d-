import Foundation
import CoreMIDI
import XCTest
@testable import XPd

@MainActor
final class MIDIOutputServiceTests: XCTestCase {
    private final class MonitorRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MIDIOutputService.MonitorEvent] = []

        func record(_ event: MIDIOutputService.MonitorEvent) {
            lock.lock(); defer { lock.unlock() }
            storage.append(event)
        }

        var events: [MIDIOutputService.MonitorEvent] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
    }

    private final class RecordingBackend: MIDIOutputBackend, @unchecked Sendable {
        struct Sent: Equatable, Sendable {
            let endpointID: MIDIUniqueID
            let words: [UInt32]
        }

        var nextID: MIDIUniqueID = 100
        var idsByName: [String: MIDIUniqueID] = [:]
        var preferredByName: [String: MIDIUniqueID?] = [:]
        var sent: [Sent] = []
        var disposed: [MIDIUniqueID] = []
        var failures: Set<String> = []
        var sendFailuresRemaining = 0
        private let lock = NSLock()

        func createSource(name: String, preferredUniqueID: MIDIUniqueID?) throws -> MIDIBackendSource {
            lock.lock(); defer { lock.unlock() }
            preferredByName[name] = preferredUniqueID
            if failures.contains(name) {
                throw MIDIOutputService.ServiceError.backend("synthetic failure for \(name)")
            }
            let id = idsByName[name] ?? {
                let value = nextID
                nextID += 1
                return value
            }()
            idsByName[name] = id
            return MIDIBackendSource(endpointID: id, stableIDWarning: nil)
        }

        func send(words: [UInt32], to endpointID: MIDIUniqueID) throws {
            lock.lock(); defer { lock.unlock() }
            if sendFailuresRemaining > 0 {
                sendFailuresRemaining -= 1
                throw MIDIOutputService.ServiceError.backend("synthetic send failure")
            }
            guard idsByName.values.contains(endpointID) else {
                throw MIDIOutputService.ServiceError.backend("unknown endpoint")
            }
            sent.append(Sent(endpointID: endpointID, words: words))
        }

        func dispose(endpointID: MIDIUniqueID) {
            lock.lock(); defer { lock.unlock() }
            disposed.append(endpointID)
        }
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "XPdTests.MIDIOutputService.\(UUID().uuidString)")!
    }

    func testExactMIDI10UMPChannelVoiceWords() {
        XCTAssertEqual(MIDIOutputService.encodeNoteOn(channel: 1, note: 60, velocity: 100), 0x20903C64)
        XCTAssertEqual(MIDIOutputService.encodeNoteOff(channel: 16, note: 60, velocity: 0), 0x20803C00 | 0x000F0000)
        XCTAssertEqual(MIDIOutputService.encodeControlChange(channel: 2, controller: 21, value: 127), 0x20B1157F)
        XCTAssertEqual(MIDIOutputService.encodeProgramChange(channel: 1, program: 12), 0x20C00C00)
        XCTAssertEqual(MIDIOutputService.encodePitchBend(channel: 1, value: 8192), 0x20E00040)
    }

    func testMonitorReportsExactSuccessfulAndFailedOutputAttempts() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let recorder = MonitorRecorder()
        await service.setMonitorSink { [recorder] event in recorder.record(event) }
        let mapping = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 7, interaction: .momentary
        )

        _ = await service.sendButton(mapping, origin: .init("monitor-success"))
        backend.sendFailuresRemaining = 1
        _ = await service.release(origin: .init("monitor-success"))

        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].sequence, 1)
        XCTAssertEqual(events[0].outcome, .sent)
        XCTAssertEqual(events[0].port, .performance)
        XCTAssertEqual(events[0].word, 0x20903C64)
        XCTAssertEqual(events[0].umpHex, "0x20903C64")
        XCTAssertEqual(events[1].sequence, 2)
        XCTAssertEqual(events[1].outcome, .failed)
        XCTAssertEqual(events[1].word, 0x20803C07)
        XCTAssertNotNil(events[1].error)
    }

    func testSourcesRouteToControlAndPerformanceIndependently() async {
        let backend = RecordingBackend()
        let defaults = Self.makeDefaults()
        let service = MIDIOutputService(defaults: defaults, backend: backend)
        let control = MIDIButtonMapping(
            kind: .note, outputPort: .control, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 0, interaction: .momentary
        )
        let performance = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 36,
            velocity: 112, releaseVelocity: 0, interaction: .momentary
        )

        _ = await service.sendButton(control, origin: .init("control"))
        _ = await service.sendButton(performance, origin: .init("performance"))

        XCTAssertEqual(backend.sent.map(\ .endpointID), [100, 101])
        XCTAssertEqual(backend.sent.map { $0.words[0] }, [0x20903C64, 0x20902470])
        let controlStatus = await service.endpointStatus(for: .control)
        let performanceStatus = await service.endpointStatus(for: .performance)
        XCTAssertEqual(controlStatus.name, "XP[d] Control")
        XCTAssertEqual(performanceStatus.name, "XP[d] Performance")
    }

    func testRepeatedPressDoesNotDuplicateNoteAndReleaseCleansIt() async {
        let backend = RecordingBackend()
        let defaults = Self.makeDefaults()
        let service = MIDIOutputService(defaults: defaults, backend: backend)
        let mapping = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 7, interaction: .momentary
        )
        let origin = MIDIOutputService.Origin("K1")

        _ = await service.sendButton(mapping, origin: origin)
        _ = await service.sendButton(mapping, origin: origin)
        XCTAssertEqual(backend.sent.count, 1)
        let activeAfterPress = await service.activeNoteCount()
        XCTAssertEqual(activeAfterPress, 1)

        _ = await service.release(origin: origin)
        XCTAssertEqual(backend.sent.map { $0.words[0] }, [0x20903C64, 0x20803C07])
        let activeAfterRelease = await service.activeNoteCount()
        XCTAssertEqual(activeAfterRelease, 0)
        _ = await service.release(origin: origin)
        XCTAssertEqual(backend.sent.count, 2)
    }

    func testOneShotNoteAlwaysEmitsMatchingNoteOff() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let mapping = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 9, interaction: .oneShot
        )

        _ = await service.sendButton(mapping, origin: .init("one-shot"))

        XCTAssertEqual(backend.sent.map { $0.words[0] }, [0x20903C64, 0x20803C09])
        let activeNotes = await service.activeNoteCount()
        XCTAssertEqual(activeNotes, 0)
    }

    func testReleaseLayerClearsProgramAndNoActionPressedOrigins() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let program = MIDIButtonMapping(
            kind: .program, outputPort: .control, channel: 1, program: 12
        )
        let noAction = MIDIButtonMapping(kind: .noAction, outputPort: .control, channel: 1)
        let origin = MIDIOutputService.Origin("layer-button", layer: 2)

        _ = await service.sendButton(program, origin: origin)
        let repeatedResult = await service.sendButton(program, origin: origin)
        XCTAssertEqual(repeatedResult, .success(.ignored))
        _ = await service.releaseLayer(2)
        _ = await service.sendButton(noAction, origin: origin)
        _ = await service.releaseLayer(2)
        _ = await service.sendButton(program, origin: origin)

        XCTAssertEqual(backend.sent.map { $0.words[0] }, [0x20C00C00, 0x20C00C00])
    }

    func testPanicClearsToggleAndPressedLogicalState() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let toggle = MIDIButtonMapping(
            kind: .cc, outputPort: .control, channel: 1, controller: 21,
            pressValue: 127, releaseValue: 0, interaction: .toggle
        )
        let program = MIDIButtonMapping(
            kind: .program, outputPort: .control, channel: 1, program: 12
        )

        _ = await service.sendButton(toggle, origin: .init("toggle"))
        _ = await service.release(origin: .init("toggle"))
        _ = await service.sendButton(program, origin: .init("program"))
        _ = await service.sendButton(program, origin: .init("program"))
        _ = await service.panic()
        _ = await service.sendButton(toggle, origin: .init("toggle"))
        _ = await service.sendButton(program, origin: .init("program"))

        XCTAssertEqual(backend.sent.map { $0.words[0] }, [
            0x20B0157F, 0x20C00C00, 0x20B0157F, 0x20C00C00
        ])
    }

    func testFailedToggleSendDoesNotAdvanceLogicalStateOrLoseTrackedNotes() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let control = MIDIButtonMapping(
            kind: .cc, outputPort: .control, channel: 1, controller: 21,
            pressValue: 127, releaseValue: 0, interaction: .toggle
        )
        let note = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 0, interaction: .toggle
        )

        backend.sendFailuresRemaining = 1
        let failedControlSend = await service.sendButton(control, origin: .init("control"))
        XCTAssertNil(try? failedControlSend.get())
        _ = await service.release(origin: .init("control"))
        _ = await service.sendButton(control, origin: .init("control"))
        XCTAssertEqual(backend.sent.last?.words[0], 0x20B0157F)

        _ = await service.sendButton(note, origin: .init("note"))
        _ = await service.release(origin: .init("note"))
        backend.sendFailuresRemaining = 1
        let failedNoteOff = await service.sendButton(note, origin: .init("note"))
        XCTAssertNil(try? failedNoteOff.get())
        let activeAfterFailedOff = await service.activeNoteCount()
        XCTAssertEqual(activeAfterFailedOff, 1)
        _ = await service.release(origin: .init("note"))
        _ = await service.sendButton(note, origin: .init("note"))
        XCTAssertEqual(backend.sent.last?.words[0], 0x20803C00)
        let activeAfterRetry = await service.activeNoteCount()
        XCTAssertEqual(activeAfterRetry, 0)
    }

    func testChordAndPanicReleaseOrderingIncludesAllNotesOff() async {
        let backend = RecordingBackend()
        let defaults = Self.makeDefaults()
        let service = MIDIOutputService(defaults: defaults, backend: backend)
        let mapping = MIDIButtonMapping(
            kind: .chord, outputPort: .performance, channel: 2,
            velocity: 100, releaseVelocity: 0, chord: [60, 64, 67], interaction: .momentary
        )
        _ = await service.sendButton(mapping, origin: .init("pad"))
        _ = await service.panic()

        XCTAssertEqual(backend.sent.map { $0.words[0] }, [
            0x20913C64, 0x20914064, 0x20914364,
            0x20813C00, 0x20814000, 0x20814300, 0x20B17B00
        ])
        let activeAfterPanic = await service.activeNoteCount()
        XCTAssertEqual(activeAfterPanic, 0)
    }

    func testWheelRelativeCCAndAbsoluteCCClamp() async {
        let backend = RecordingBackend()
        let defaults = Self.makeDefaults()
        let service = MIDIOutputService(defaults: defaults, backend: backend)
        let relative = MIDIWheelMapping(
            kind: .relativeCC, outputPort: .control, channel: 1, controller: 21,
            clockwiseValue: 1, counterClockwiseValue: 127
        )
        _ = await service.wheel(.clockwise, mapping: relative)
        _ = await service.wheel(.counterClockwise, mapping: relative)

        let absolute = MIDIWheelMapping(
            kind: .absoluteCC, outputPort: .control, channel: 1, controller: 22,
            stepSize: 40
        )
        for _ in 0..<4 { _ = await service.wheel(.clockwise, mapping: absolute) }
        for _ in 0..<6 { _ = await service.wheel(.counterClockwise, mapping: absolute) }

        let words = backend.sent.map { $0.words[0] }
        XCTAssertEqual(words[0], 0x20B01501)
        XCTAssertEqual(words[1], 0x20B0157F)
        XCTAssertEqual(words[5], 0x20B0167F)
        XCTAssertEqual(words.last, 0x20B01600)
    }

    func testWheelReversedDirectionAppliesOnceToRelativeAbsoluteAndPitchBend() async throws {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let relative = MIDIWheelMapping(
            kind: .relativeCC, outputPort: .control, channel: 1, controller: 21,
            clockwiseValue: 1, counterClockwiseValue: 127, reversedDirection: true
        )
        let absolute = MIDIWheelMapping(
            kind: .absoluteCC, outputPort: .control, channel: 1, controller: 22,
            stepSize: 10, reversedDirection: true
        )
        let pitch = MIDIWheelMapping(
            kind: .pitchBendNudgeReturn, outputPort: .performance, channel: 1,
            reversedDirection: true, pitchBendStep: 512, returnDelay: 60, returnDuration: 0
        )

        _ = await service.wheel(.clockwise, mapping: relative)
        _ = await service.wheel(.clockwise, mapping: absolute)
        _ = await service.wheel(.clockwise, mapping: pitch)

        XCTAssertEqual(backend.sent[0].words[0], 0x20B0157F)
        XCTAssertEqual(backend.sent[1].words[0], 0x20B01636)
        XCTAssertEqual(backend.sent[2].words[0], 0x20E0003C)
    }

    func testPitchBendNudgeReturnsToCenterAndResetIsDeterministic() async throws {
        let backend = RecordingBackend()
        let defaults = Self.makeDefaults()
        let service = MIDIOutputService(defaults: defaults, backend: backend)
        let mapping = MIDIWheelMapping(
            kind: .pitchBendNudgeReturn, outputPort: .performance, channel: 1,
            pitchBendStep: 512, returnDelay: 0, returnDuration: 0
        )
        _ = await service.wheel(.clockwise, mapping: mapping)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(backend.sent.first?.words.first, 0x20E00044)
        XCTAssertEqual(backend.sent.last?.words.first, 0x20E00040)

        let slower = MIDIWheelMapping(
            kind: .pitchBendNudgeReturn, outputPort: .performance, channel: 1,
            pitchBendStep: 1024, returnDelay: 60, returnDuration: 60
        )
        _ = await service.wheel(.clockwise, mapping: slower)
        await service.resetPitchBend()
        XCTAssertEqual(backend.sent.last?.words.first, 0x20E00040)
    }

    func testPanicCentersPitchBendAndResetsAbsoluteWheelState() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let absolute = MIDIWheelMapping(
            kind: .absoluteCC, outputPort: .control, channel: 1, controller: 22, stepSize: 10
        )
        let pitch = MIDIWheelMapping(
            kind: .pitchBendNudgeReturn, outputPort: .performance, channel: 1,
            pitchBendStep: 512, returnDelay: 60, returnDuration: 0
        )

        _ = await service.wheel(.clockwise, mapping: absolute)
        _ = await service.wheel(.clockwise, mapping: pitch)
        _ = await service.panic()
        _ = await service.wheel(.clockwise, mapping: absolute)
        _ = await service.wheel(.clockwise, mapping: pitch)

        XCTAssertEqual(backend.sent.map { $0.words[0] }, [
            0x20B0164A, 0x20E00044, 0x20E00040, 0x20B0164A, 0x20E00044
        ])
    }

    func testPanicReconcilesFailedReleaseWhenAllNotesOffSucceeds() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let note = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 0, interaction: .momentary
        )
        let origin = MIDIOutputService.Origin("panic-retry")

        _ = await service.sendButton(note, origin: origin)
        backend.sendFailuresRemaining = 1 // individual Note Off fails
        let result = await service.panic() // defensive CC123 succeeds

        XCTAssertEqual(result, .success(.emitted))
        let activeAfterReconciledPanic = await service.activeNoteCount()
        XCTAssertEqual(activeAfterReconciledPanic, 0)
        _ = await service.sendButton(note, origin: origin)
        XCTAssertEqual(backend.sent.map { $0.words[0] }, [0x20903C64, 0x20B07B00, 0x20903C64])
    }

    func testPanicRetainsFailedMomentaryControlDespiteSuccessfulAllNotesOff() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let mapping = MIDIButtonMapping(
            kind: .cc, outputPort: .control, channel: 1, controller: 21,
            pressValue: 127, releaseValue: 0, interaction: .momentary
        )
        let origin = MIDIOutputService.Origin("momentary-control")

        _ = await service.sendButton(mapping, origin: origin)
        backend.sendFailuresRemaining = 1 // mapped CC off fails; CC123 succeeds
        let firstPanic = await service.panic()
        if case .failure = firstPanic {
            // Expected: CC123 cannot stand in for the mapping's CC21 off.
        } else {
            XCTFail("Panic must report the still-retryable momentary CC release")
        }
        let retainedControls = await service.activeControlCount()
        XCTAssertEqual(retainedControls, 1)

        let retry = await service.panic()
        XCTAssertNotNil(try? retry.get())
        let controlsAfterRetry = await service.activeControlCount()
        XCTAssertEqual(controlsAfterRetry, 0)
        XCTAssertTrue(backend.sent.contains { $0.words[0] == 0x20B01500 })
    }

    func testPanicRetainsRetryableStateWhenIndividualAndDefensiveCleanupFail() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let note = MIDIButtonMapping(
            kind: .note, outputPort: .performance, channel: 1, note: 60,
            velocity: 100, releaseVelocity: 0, interaction: .momentary
        )
        let origin = MIDIOutputService.Origin("panic-failure")

        _ = await service.sendButton(note, origin: origin)
        backend.sendFailuresRemaining = 2 // Note Off and CC123 both fail
        let failed = await service.panic()
        if case .failure = failed {
            // Expected: the active note remains retryable.
        } else {
            XCTFail("Panic should report failed defensive cleanup")
        }
        let activeAfterFailedPanic = await service.activeNoteCount()
        XCTAssertEqual(activeAfterFailedPanic, 1)

        let retry = await service.panic()
        XCTAssertEqual(retry, .success(.emitted))
        let activeAfterRetry = await service.activeNoteCount()
        XCTAssertEqual(activeAfterRetry, 0)
    }

    func testSuccessfulEmitClearsStaleError() async {
        let backend = RecordingBackend()
        let service = MIDIOutputService(defaults: Self.makeDefaults(), backend: backend)
        let relative = MIDIWheelMapping(
            kind: .relativeCC, outputPort: .control, channel: 1, controller: 21,
            clockwiseValue: 1, counterClockwiseValue: 127
        )

        backend.sendFailuresRemaining = 1
        _ = await service.wheel(.clockwise, mapping: relative)
        let staleError = await service.lastError
        XCTAssertNotNil(staleError)
        _ = await service.wheel(.clockwise, mapping: relative)
        let recoveredError = await service.lastError
        XCTAssertNil(recoveredError)
    }

    func testEndpointFailuresAreReportedPerPortAndSavedIDsAreReapplied() async {
        let defaults = Self.makeDefaults()
        let firstBackend = RecordingBackend()
        _ = MIDIOutputService(defaults: defaults, backend: firstBackend)

        let secondBackend = RecordingBackend()
        secondBackend.idsByName["XP[d] Control"] = 301
        secondBackend.idsByName["XP[d] Performance"] = 302
        let second = MIDIOutputService(defaults: defaults, backend: secondBackend)

        XCTAssertEqual(secondBackend.preferredByName["XP[d] Control"]!, 100)
        XCTAssertEqual(secondBackend.preferredByName["XP[d] Performance"]!, 101)
        let secondControlStatus = await second.endpointStatus(for: .control)
        XCTAssertEqual(secondControlStatus.endpointID, 301)

        let failing = RecordingBackend()
        failing.failures = ["XP[d] Control"]
        let service = MIDIOutputService(defaults: defaults, backend: failing)
        let controlStatus = await service.endpointStatus(for: .control)
        let performanceStatus = await service.endpointStatus(for: .performance)
        XCTAssertFalse(controlStatus.isAvailable)
        XCTAssertNotNil(controlStatus.error)
        XCTAssertTrue(performanceStatus.isAvailable)
    }
}
