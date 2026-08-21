import Foundation
import XCTest
@testable import XPd

@MainActor
final class ButtonGestureRecognizerTests: XCTestCase {
    private final class ScheduledItem {
        let deadline: TimeInterval
        let action: @MainActor () -> Void
        var isCancelled = false

        init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.deadline = deadline
            self.action = action
        }
    }

    @MainActor
    private final class TestScheduler {
        private(set) var now: TimeInterval = 0
        private var items: [ScheduledItem] = []

        func schedule(
            delay: TimeInterval,
            action: @escaping @MainActor () -> Void
        ) -> GestureScheduledAction {
            let item = ScheduledItem(deadline: now + delay, action: action)
            items.append(item)
            return GestureScheduledAction { item.isCancelled = true }
        }

        func advance(by interval: TimeInterval) {
            let target = now + interval
            while let next = items
                .filter({ !$0.isCancelled && $0.deadline <= target })
                .min(by: { $0.deadline < $1.deadline }) {
                items.removeAll { $0 === next }
                now = next.deadline
                next.action()
            }
            now = target
        }
    }

    func testTapWaitsUntilDoubleWindowExpires() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.press(.k1)
        recognizer.release(.k1)
        scheduler.advance(by: 0.299)
        XCTAssertTrue(gestures.value.isEmpty)

        scheduler.advance(by: 0.001)
        XCTAssertEqual(gestures.value, [.init(control: .k1, gesture: .tap)])
    }

    func testHoldFiresOnceAndSuppressesTap() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.press(.k2)
        scheduler.advance(by: 0.72)
        scheduler.advance(by: 1)
        recognizer.release(.k2)
        scheduler.advance(by: 1)

        XCTAssertEqual(gestures.value, [.init(control: .k2, gesture: .hold)])
    }

    func testSecondShortPressProducesOnlyDouble() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.press(.k3)
        recognizer.release(.k3)
        scheduler.advance(by: 0.10)
        recognizer.press(.k3)
        recognizer.release(.k3)
        scheduler.advance(by: 1)

        XCTAssertEqual(gestures.value, [.init(control: .k3, gesture: .doubleTap)])
    }

    func testTwoSlowPressesProduceTwoTaps() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.press(.k4)
        recognizer.release(.k4)
        scheduler.advance(by: 0.30)
        recognizer.press(.k4)
        recognizer.release(.k4)
        scheduler.advance(by: 0.30)

        XCTAssertEqual(gestures.value, [
            .init(control: .k4, gesture: .tap),
            .init(control: .k4, gesture: .tap)
        ])
    }

    func testDuplicateDownReportsAndCancellationDoNotExecute() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.press(.k5)
        recognizer.press(.k5)
        recognizer.release(.k5)
        recognizer.cancelAll()
        scheduler.advance(by: 1)

        XCTAssertTrue(gestures.value.isEmpty)
    }

    func testHoldingSecondPressProducesHoldInsteadOfDouble() {
        let (recognizer, scheduler, gestures) = makeRecognizer()

        recognizer.press(.k6)
        recognizer.release(.k6)
        scheduler.advance(by: 0.10)
        recognizer.press(.k6)
        scheduler.advance(by: 0.72)
        recognizer.release(.k6)
        scheduler.advance(by: 1)

        XCTAssertEqual(gestures.value, [.init(control: .k6, gesture: .hold)])
    }

    private func makeRecognizer() -> (
        ButtonGestureRecognizer,
        TestScheduler,
        GestureRecorder
    ) {
        let scheduler = TestScheduler()
        let recorder = GestureRecorder()
        let recognizer = ButtonGestureRecognizer { delay, action in
            scheduler.schedule(delay: delay, action: action)
        }
        recognizer.onGesture = { control, gesture in
            recorder.value.append(.init(control: control, gesture: gesture))
        }
        return (recognizer, scheduler, recorder)
    }
}

private struct RecordedGesture: Equatable {
    let control: RemoteControl
    let gesture: GestureKind
}

@MainActor
private final class GestureRecorder {
    var value: [RecordedGesture] = []
}
