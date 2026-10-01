import AppKit
@testable import SunMouse
import XCTest

final class SmoothedScrollingTransformerTests: XCTestCase {
    func testDiscreteWheelIsConsumedAndReemittedAsFiniteSyntheticSeries() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        let transformer = makeTransformer(now: { clock.now }) { events.append($0.copy() ?? $0) }
        let input = try makeScrollEvent(wheel1: 1)

        XCTAssertNil(transformer.transform(input, in: .init(device: nil)))
        tick(transformer, clock: clock, count: 120)

        let scrollEvents = events.filter { $0.type == .scrollWheel }
        XCTAssertFalse(scrollEvents.isEmpty)
        XCTAssertTrue(scrollEvents.allSatisfy(\.isSunMouseSyntheticEvent))
        XCTAssertEqual(ScrollWheelEventView(scrollEvents.first!).scrollPhase, .began)
        XCTAssertEqual(ScrollWheelEventView(scrollEvents.last!).momentumPhase, .end)
        XCTAssertGreaterThan(totalVerticalDistance(scrollEvents), 0)
    }

    func testContinuousTrackpadEventPassesThroughUnchanged() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        let transformer = makeTransformer(now: { clock.now }) { events.append($0.copy() ?? $0) }
        let input = try makeScrollEvent(wheel1: 9)
        let view = ScrollWheelEventView(input)
        view.continuous = true
        view.scrollPhase = .changed

        let result = try XCTUnwrap(transformer.transform(input, in: .init(device: nil)))

        XCTAssertTrue(result === input)
        XCTAssertEqual(ScrollWheelEventView(result).deltaY, 9)
        XCTAssertEqual(ScrollWheelEventView(result).scrollPhase, .changed)
        tick(transformer, clock: clock, count: 10)
        XCTAssertTrue(events.isEmpty)
    }

    func testDiagonalWheelEventPassesThroughUnchanged() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        let transformer = makeTransformer(
            horizontal: true,
            now: { clock.now }
        ) { events.append($0.copy() ?? $0) }
        let input = try makeScrollEvent(wheel1: 2, wheel2: 3)

        let result = try XCTUnwrap(transformer.transform(input, in: .init(device: nil)))

        XCTAssertTrue(result === input)
        XCTAssertEqual(ScrollWheelEventView(result).deltaY, 2)
        XCTAssertEqual(ScrollWheelEventView(result).deltaX, 3)
        tick(transformer, clock: clock, count: 10)
        XCTAssertTrue(events.isEmpty)
    }

    func testDirectionChangeStopsCurrentSyntheticAnimation() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        let transformer = makeTransformer(now: { clock.now }) { events.append($0.copy() ?? $0) }

        XCTAssertNil(transformer.transform(try makeScrollEvent(wheel1: 1), in: .init(device: nil)))
        tick(transformer, clock: clock, count: 8)
        XCTAssertFalse(events.isEmpty)

        events.removeAll()
        clock.now += 1.0 / 120.0
        XCTAssertNil(transformer.transform(try makeScrollEvent(wheel1: -1), in: .init(device: nil)))
        tick(transformer, clock: clock, count: 30)
        XCTAssertTrue(events.isEmpty)
    }

    func testBouncingDisabledKeepsSyntheticPhasesUnset() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        var settings = Scheme.Scrolling.Smoothed.Preset.easeInOut.defaultConfiguration
        settings.bouncing = false
        let transformer = SmoothedScrollingTransformer(
            smoothed: .init(vertical: settings),
            now: { clock.now },
            eventSink: { events.append($0.copy() ?? $0) }
        )

        XCTAssertNil(transformer.transform(try makeScrollEvent(wheel1: 1), in: .init(device: nil)))
        tick(transformer, clock: clock, count: 120)

        let scrollEvents = events.filter { $0.type == .scrollWheel }
        XCTAssertFalse(scrollEvents.isEmpty)
        XCTAssertTrue(scrollEvents.allSatisfy {
            let view = ScrollWheelEventView($0)
            return view.scrollPhase == nil && view.momentumPhase == .none
        })
    }

    func testHighResolutionUnitConversionPreservesSingleRawTick() {
        let units = LogitechHighResolutionWheelUnitReader.UnitResolution(
            rawUnits: 1,
            acceleratedUnits: 7,
            units: 7
        )
        XCTAssertEqual(SmoothedScrollingTransformer.smoothedHighResolutionUnits(from: units), 1)
    }

    func testHighResolutionUnitConversionUsesAccelerationHintForCoalescedTicks() {
        let units = LogitechHighResolutionWheelUnitReader.UnitResolution(
            rawUnits: 4,
            acceleratedUnits: 8,
            units: 8
        )
        XCTAssertEqual(SmoothedScrollingTransformer.smoothedHighResolutionUnits(from: units), 7)
    }

    private func makeTransformer(
        horizontal: Bool = false,
        now: @escaping () -> TimeInterval,
        eventSink: @escaping (CGEvent) -> Void
    ) -> SmoothedScrollingTransformer {
        let settings = Scheme.Scrolling.Smoothed.Preset.easeInOut.defaultConfiguration
        return SmoothedScrollingTransformer(
            smoothed: .init(vertical: settings, horizontal: horizontal ? settings : nil),
            now: now,
            eventSink: eventSink
        )
    }

    private func makeScrollEvent(wheel1: Int32, wheel2: Int32 = 0) throws -> CGEvent {
        try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: 0
        ))
    }

    private func tick(
        _ transformer: SmoothedScrollingTransformer,
        clock: TestClock,
        count: Int
    ) {
        for _ in 0 ..< count {
            clock.now += 1.0 / 120.0
            transformer.tick()
        }
    }

    private func totalVerticalDistance(_ events: [CGEvent]) -> Double {
        events.reduce(0) { $0 + abs(ScrollWheelEventView($1).deltaYPt) }
    }
}

private final class TestClock {
    var now: TimeInterval = 1
}

extension SmoothedScrollingTransformerTests {
    func testMMFOffStillUsesCustomSpeedImmediatelyInsteadOfInheritedSmoothing() throws {
        var events: [CGEvent] = []
        let config = SMScrollConfiguration(smoothness: .off, speed: .medium)
        let transformer = SmoothedScrollingTransformer(smoothed: .init(vertical: config.runtimeConfiguration), now: { 1 }, eventSink: { events.append($0) })
        XCTAssertNil(transformer.transform(try makeScrollEvent(wheel1: 7), in: .init(device: nil)))
        let scrolls = events.filter { $0.type == .scrollWheel }
        XCTAssertEqual(totalVerticalDistance(scrolls), 30, accuracy: 0.001)
        XCTAssertEqual(ScrollWheelEventView(scrolls[0]).deltaYFixedPt, 3)
        XCTAssertFalse(ScrollWheelEventView(scrolls[0]).continuous)
        XCTAssertTrue(scrolls.allSatisfy { ScrollWheelEventView($0).scrollPhase == nil && ScrollWheelEventView($0).momentumPhase == .none })
    }

    func testMMFSystemSpeedUsesOriginalPointDelta() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        let config = SMScrollConfiguration(smoothness: .regular, speed: .system)
        let transformer = SmoothedScrollingTransformer(smoothed: .init(vertical: config.runtimeConfiguration), now: { clock.now }, eventSink: { events.append($0) })
        let input = try makeScrollEvent(wheel1: 7)
        ScrollWheelEventView(input).deltaYPt = 17
        XCTAssertNil(transformer.transform(input, in: .init(device: nil)))
        tick(transformer, clock: clock, count: 120)
        XCTAssertEqual(totalVerticalDistance(events.filter { $0.type == .scrollWheel }), 17, accuracy: 1)
    }

    func testMMFPreciseModifierIsAnimatedAndSubpixelDistanceSurvives() throws {
        var events: [CGEvent] = []
        let clock = TestClock()
        let config = SMScrollConfiguration(smoothness: .high, speed: .medium)
        let transformer = SmoothedScrollingTransformer(smoothed: .init(vertical: config.runtimeConfiguration), now: { clock.now }, eventSink: { events.append($0) })
        let input = try makeScrollEvent(wheel1: 7)
        input.setIntegerValueField(.eventSourceUserData, value: SMRuntime.preciseMarker)
        XCTAssertNil(transformer.transform(input, in: .init(device: nil)))
        XCTAssertTrue(events.isEmpty)
        tick(transformer, clock: clock, count: 120)
        XCTAssertEqual(totalVerticalDistance(events.filter { $0.type == .scrollWheel }), 1, accuracy: 0.001)
    }
}

extension SmoothedScrollingTransformerTests {
    func testMMFRegularAndHighConserveIntegerDistanceThroughEntireDelivery() throws {
        for smoothness in [SMScrollConfiguration.Smoothness.regular, .high] {
            var events: [CGEvent] = []
            let clock = TestClock()
            let config = SMScrollConfiguration(smoothness: smoothness, speed: .medium)
            let transformer = SmoothedScrollingTransformer(smoothed: .init(vertical: config.runtimeConfiguration), now: { clock.now }, eventSink: { events.append($0) }, scheduleTimer: { _, _, _ in nil })
            XCTAssertNil(transformer.transform(try makeScrollEvent(wheel1: 7), in: .init(device: nil)))
            tick(transformer, clock: clock, count: 120)
            XCTAssertEqual(totalVerticalDistance(events.filter { $0.type == .scrollWheel }), smoothness == .regular ? 60 : 90, accuracy: 0.001)
        }
    }
}
