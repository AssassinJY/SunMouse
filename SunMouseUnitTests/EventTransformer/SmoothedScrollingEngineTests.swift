import XCTest
@testable import SunMouse

final class SmoothedScrollingEngineTests: XCTestCase {
    func testSingleTickUsesFiniteDistanceAnimationAndStops() {
        var engine = makeEngine()
        engine.feed(deltaX: 0, deltaY: 10, timestamp: 1)

        let emissions = drain(&engine, from: 1)
        let distance = emissions.reduce(0) { $0 + $1.deltaY }

        XCTAssertEqual(distance, 11, accuracy: 0.02)
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(emissions.contains { $0.phase == .touchBegan })
        XCTAssertTrue(emissions.contains { $0.phase == .touchEnded })
        XCTAssertTrue(emissions.contains { $0.phase == .momentumEnded })
    }

    func testNewTickCombinesUnfinishedDistanceInsteadOfReplacingIt() {
        var engine = makeEngine()
        engine.feed(deltaX: 0, deltaY: 10, timestamp: 1)
        let first = engine.advance(to: 1.01)?.deltaY ?? 0
        engine.feed(deltaX: 0, deltaY: 10, timestamp: 1.05)

        let rest = drain(&engine, from: 1.05).reduce(0) { $0 + $1.deltaY }
        XCTAssertEqual(first + rest, 22, accuracy: 0.02)
    }

    func testDirectionChangeCancelsAnimationAndConsumesOpposingTick() {
        var engine = makeEngine()
        engine.feed(deltaX: 0, deltaY: 10, timestamp: 1)
        _ = engine.advance(to: 1.01)
        engine.feed(deltaX: 0, deltaY: -10, timestamp: 1.02)

        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.advance(to: 1.03))
    }

    func testFastTicksTravelFartherThanSlowTicksWhenAccelerationEnabled() {
        var slow = makeEngine(acceleration: 4)
        slow.feed(deltaX: 0, deltaY: 10, timestamp: 1)
        slow.feed(deltaX: 0, deltaY: 10, timestamp: 1.25)
        let slowDistance = drain(&slow, from: 1.25).reduce(0) { $0 + $1.deltaY }

        var fast = makeEngine(acceleration: 4)
        fast.feed(deltaX: 0, deltaY: 10, timestamp: 1)
        fast.feed(deltaX: 0, deltaY: 10, timestamp: 1.025)
        let fastDistance = drain(&fast, from: 1.025).reduce(0) { $0 + $1.deltaY }

        XCTAssertGreaterThan(fastDistance, slowDistance)
    }

    func testContinuousGestureInputIsIgnoredByDiscreteWheelEngine() {
        var engine = makeEngine()
        engine.feed(deltaX: 0, deltaY: 10, timestamp: 1, inputKind: .continuousGesture)
        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.advance(to: 1.01))
    }

    func testExclusiveAxisCanBeReplaced() {
        var engine = makeEngine(horizontal: true)
        engine.feed(deltaX: 0, deltaY: 10, timestamp: 1)
        XCTAssertEqual(engine.exclusiveActiveAxis, .vertical)
        engine.resetOtherAxis(ifExclusiveIncomingAxis: .horizontal)
        XCTAssertNil(engine.exclusiveActiveAxis)
    }

    private func makeEngine(
        acceleration: Decimal = 0,
        horizontal: Bool = false
    ) -> SmoothedScrollingEngine {
        let settings = Scheme.Scrolling.Smoothed(
            enabled: true,
            preset: .easeInOut,
            response: 0.45,
            speed: 1,
            acceleration: acceleration,
            inertia: 0.65,
            bouncing: true
        )
        return SmoothedScrollingEngine(smoothed: .init(
            vertical: settings,
            horizontal: horizontal ? settings : nil
        ))
    }

    private func drain(
        _ engine: inout SmoothedScrollingEngine,
        from start: TimeInterval
    ) -> [SmoothedScrollingEngine.Emission] {
        var result: [SmoothedScrollingEngine.Emission] = []
        var timestamp = start
        for _ in 0 ..< 240 where engine.isRunning {
            timestamp += 1.0 / 120.0
            if let emission = engine.advance(to: timestamp) { result.append(emission) }
        }
        return result
    }
}

extension SmoothedScrollingEngineTests {
    func testMMFRegularMediumSingleTickIs60PointsRegardlessOfSystemLineAcceleration() {
        let config = SMScrollConfiguration(smoothness: .regular, speed: .medium)
        for input in [36.0, 252.0] {
            var engine = SmoothedScrollingEngine(smoothed: .init(vertical: config.runtimeConfiguration))
            engine.feed(deltaX: 0, deltaY: input, timestamp: 1)
            let emissions = drain(&engine, from: 1)
            XCTAssertEqual(emissions.reduce(0) { $0 + $1.deltaY }, 60, accuracy: 0.001)
            XCTAssertFalse(engine.isRunning)
        }
    }

    func testMMFUsesReferenceSensitivityEndpointsAndRollingTickIntervals() {
        let config = SMScrollConfiguration(smoothness: .regular, speed: .medium)
        var dynamics = MMFScrollDynamics(configuration: config)
        XCTAssertEqual(dynamics.distance(input: 36, timestamp: 1), 60)
        XCTAssertEqual(dynamics.distance(input: 252, timestamp: 1.015), 120)
        var precise = MMFScrollDynamics(configuration: config, mode: .precise)
        XCTAssertEqual(precise.distance(input: 36, timestamp: 1), 1)
        XCTAssertEqual(precise.distance(input: 36, timestamp: 1.015), 20)
    }

    func testMMFRegularCurveHasConstantSpeedThenAnalyticDragAndFiniteDistance() {
        let curve = MMFScrollCurve(distance: 60, baseDuration: 0.18, coefficient: 23, exponent: 1, stopSpeed: 30)
        XCTAssertEqual(curve.value(at: 0.03), 10, accuracy: 0.001)
        XCTAssertGreaterThan(curve.duration, 0.18)
        let tailStart = curve.transitionTime
        let earlyTail = curve.value(at: tailStart + 0.02) - curve.value(at: tailStart)
        let lateTail = curve.value(at: tailStart + 0.04) - curve.value(at: tailStart + 0.02)
        XCTAssertGreaterThan(earlyTail, lateTail)
        XCTAssertEqual(curve.value(at: curve.duration), 60, accuracy: 0.001)
    }

    func testMMFSystemSpeedPreservesPointDistance() {
        var engine = SmoothedScrollingEngine(smoothed: .init(vertical: SMScrollConfiguration(smoothness: .regular, speed: .system).runtimeConfiguration))
        engine.feed(deltaX: 0, deltaY: 17, timestamp: 1)
        XCTAssertEqual(drain(&engine, from: 1).reduce(0) { $0 + $1.deltaY }, 17, accuracy: 0.001)
    }

    func testMMFHighTrackpadMomentumStartsAtDragTransition() {
        let config = SMScrollConfiguration(smoothness: .high, speed: .medium)
        var engine = SmoothedScrollingEngine(smoothed: .init(vertical: config.runtimeConfiguration))
        engine.feed(deltaX: 0, deltaY: 36, timestamp: 1)
        let emissions = drain(&engine, from: 1)
        XCTAssertEqual(emissions.reduce(0) { $0 + $1.deltaY }, 90, accuracy: 0.001)
        XCTAssertEqual(emissions.first?.phase, .touchBegan)
        XCTAssertEqual(emissions.last?.phase, .momentumEnded)
        let touchDistance = emissions.filter { $0.phase == .touchBegan || $0.phase == .touchChanged }.reduce(0) { $0 + $1.deltaY }
        XCTAssertGreaterThan(touchDistance, 0)
        XCTAssertLessThan(touchDistance, 90)
    }
}
