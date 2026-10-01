import XCTest
@testable import SunMouse

final class SMBugFixTests: XCTestCase {
    func testTriggerKindsProvideCompatibleDefaultActions() {
        for triggerKind in SMTrigger.Kind.allCases {
            XCTAssertTrue(
                triggerKind.compatibleActionKinds.contains(triggerKind.defaultActionKind),
                "\(triggerKind) has an incompatible default action"
            )
        }
        XCTAssertEqual(SMTrigger.Kind.click.defaultActionKind, .builtin)
        XCTAssertEqual(SMTrigger.Kind.hold.defaultActionKind, .builtin)
        XCTAssertEqual(SMTrigger.Kind.drag.defaultActionKind, .dragScroll)
        XCTAssertEqual(SMTrigger.Kind.wheelUp.defaultActionKind, .wheelZoom)
        XCTAssertEqual(SMTrigger.Kind.wheelDown.defaultActionKind, .wheelZoom)
    }

    func testWheelRepeatConfigurationOnlyAppliesToDiscreteActions() {
        XCTAssertTrue(SMTrigger.Kind.wheelUp.supportsRepeatConfiguration(for: .shortcut))
        XCTAssertTrue(SMTrigger.Kind.wheelDown.supportsRepeatConfiguration(for: .builtin))
        XCTAssertFalse(SMTrigger.Kind.wheelUp.supportsRepeatConfiguration(for: .wheelZoom))
        XCTAssertFalse(SMTrigger.Kind.click.supportsRepeatConfiguration(for: .shortcut))
    }

    func testHorizontalModifierPreservesAlreadyHorizontalWheel() {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 24, wheel3: 0)!
        SMRuntime.makeHorizontal(e)
        XCTAssertEqual(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), 24)
    }
    func testHorizontalModifierMovesAllVerticalRepresentations() {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 24, wheel2: 0, wheel3: 0)!
        SMRuntime.makeHorizontal(e)
        XCTAssertEqual(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis2), 24)
        XCTAssertEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
        XCTAssertNotEqual(e.getIntegerValueField(.scrollWheelEventDeltaAxis2), 0)
    }
    func testTinyMovesAccumulateWhileCursorLocationIsFrozen() {
        let engine = SMInterpreter()
        var rule = SMRule(); rule.trigger.button = 1; rule.trigger.kind = .trail; rule.trigger.path = "RU"
        var config = SMConfiguration(); config.rules = [rule]
        _ = engine.process(.init(device: 1, kind: .down, button: 1, time: 0), configuration: config)
        for i in 1...10 {
            _ = engine.process(.init(device: 1, kind: .move, button: 1, time: Double(i) * 0.01, dx: 2), configuration: config)
        }
        for i in 11...20 {
            _ = engine.process(.init(device: 1, kind: .move, button: 1, time: Double(i) * 0.01, dy: -2), configuration: config)
        }
        let result = engine.process(.init(device: 1, kind: .up, button: 1, time: 0.3), configuration: config)
        XCTAssertTrue(result.effects.contains { if case let .action(r, _) = $0 { return r.id == rule.id }; return false })
        XCTAssertEqual(engine.activeCount, 0)
    }
    func testRealDraggedEventUsesChangingLocationWhenEventDeltasAreZero() throws {
        let engine = SMInterpreter()
        var rule = SMRule(); rule.trigger.button = 1; rule.trigger.kind = .trail; rule.trigger.path = "U"
        var config = SMConfiguration(); config.rules = [rule]
        let downEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100),
            mouseButton: .right
        ))
        let dragEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDragged,
            mouseCursorPosition: CGPoint(x: 100, y: 60),
            mouseButton: .right
        ))
        _ = engine.process(
            .init(device: 1, kind: .down, button: 1, time: 0, point: downEvent.location, original: downEvent),
            configuration: config
        )
        let move = engine.process(
            .init(device: 1, kind: .move, button: 1, time: 0.1, point: dragEvent.location, original: dragEvent),
            configuration: config
        )
        XCTAssertTrue(move.effects.contains { if case .trail = $0 { return true }; return false })
        let result = engine.process(
            .init(device: 1, kind: .up, button: 1, time: 0.2, point: dragEvent.location, original: dragEvent),
            configuration: config
        )
        XCTAssertTrue(result.effects.contains { if case let .action(r, _) = $0 { return r.id == rule.id }; return false })
    }
    func testTinyMovesStartContinuousDrag() {
        let engine = SMInterpreter()
        var rule = SMRule(); rule.trigger.kind = .drag; rule.action.kind = .dragScroll
        var config = SMConfiguration(); config.rules = [rule]
        _ = engine.process(.init(device: 1, kind: .down, button: 3, time: 0), configuration: config)
        var began = false
        for i in 1...10 {
            let result = engine.process(.init(device: 1, kind: .move, button: 3, time: Double(i) * 0.01, dx: 2), configuration: config)
            began = began || result.effects.contains { if case .continuous(_, _, _, 1) = $0 { return true }; return false }
        }
        XCTAssertTrue(began)
    }
    func testRecordDoubleClickWaitsForFinalRelease() {
        var engine = SMTriggerRecordingEngine()
        for t in [0.0, 0.15] {
            engine.process(.init(device: 1, kind: .down, button: 3, time: t))
            engine.process(.init(device: 1, kind: .up, button: 3, time: t + 0.05))
        }
        XCTAssertNil(engine.completed(at: 0.25))
        XCTAssertEqual(engine.completed(at: 0.6)?.clicks, 2)
        XCTAssertEqual(engine.completed(at: 0.6)?.kind, .click)
    }
    func testRecordHoldWithModifier() {
        var engine = SMTriggerRecordingEngine()
        engine.process(.init(device: 1, kind: .down, button: 4, time: 0, modifiers: CGEventFlags.maskCommand.rawValue))
        engine.process(.init(device: 1, kind: .up, button: 4, time: 0.6))
        XCTAssertEqual(engine.completed(at: 1)?.kind, .hold)
        XCTAssertEqual(engine.completed(at: 1)?.modifiers, CGEventFlags.maskCommand.rawValue)
    }
    func testRecordChordAndPhysicalWheel() {
        var engine = SMTriggerRecordingEngine()
        engine.process(.init(device: 1, kind: .down, button: 1, time: 0))
        engine.process(.init(device: 1, kind: .down, button: 3, time: 0.1))
        engine.process(.init(device: 1, kind: .wheel, button: 0, time: 0.2, dy: -1, physicalWheelSign: 1))
        engine.process(.init(device: 1, kind: .up, button: 1, time: 0.3))
        engine.process(.init(device: 1, kind: .up, button: 3, time: 0.4))
        XCTAssertEqual(engine.completed(at: 1)?.kind, .wheelUp)
        XCTAssertEqual(engine.completed(at: 1)?.held, [.init(button: 1)])
    }
    func testRecordDragSuppressesLongPress() {
        var engine = SMTriggerRecordingEngine()
        engine.process(.init(device: 1, kind: .down, button: 3, time: 0))
        for i in 1...10 { engine.process(.init(device: 1, kind: .move, button: 3, time: Double(i) * 0.02, dx: 2)) }
        engine.process(.init(device: 1, kind: .up, button: 3, time: 0.8))
        XCTAssertEqual(engine.completed(at: 1.2)?.kind, .drag)
    }
    func testWheelRecordingDoesNotTurnIntoDragOnLaterMovement() {
        var engine = SMTriggerRecordingEngine()
        engine.process(.init(device: 1, kind: .down, button: 3, time: 0))
        engine.process(.init(device: 1, kind: .wheel, button: 0, time: 0.1, dy: 1))
        engine.process(.init(device: 1, kind: .move, button: 3, time: 0.2, dx: 40))
        engine.process(.init(device: 1, kind: .up, button: 3, time: 0.3))
        XCTAssertEqual(engine.completed(at: 1)?.kind, .wheelUp)
    }

    func testSyntheticSideButtonEventsReachRuntime() throws {
        let sideButton = try XCTUnwrap(CGMouseButton(rawValue: 3))
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = try XCTUnwrap(
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: .zero,
                    mouseButton: sideButton
                )
            )
            event.isSunMouseSyntheticEvent = true
            XCTAssertTrue(SMRuntime.shouldProcess(event))
        }
    }

    func testOtherSyntheticEventsStayOutOfRuntime() throws {
        let event = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )
        )
        event.isSunMouseSyntheticEvent = true
        XCTAssertFalse(SMRuntime.shouldProcess(event))
    }

    func testRuntimeReplayEventsStayOutOfRuntime() throws {
        let sideButton = try XCTUnwrap(CGMouseButton(rawValue: 3))
        let event = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: sideButton
            )
        )
        event.setIntegerValueField(.eventSourceUserData, value: SMRuntime.marker)
        XCTAssertFalse(SMRuntime.shouldProcess(event))
    }

}

final class SMScrollConfigurationTests: XCTestCase {
    func testSideButtonDragScrollKeepsDownwardVerticalDirection() throws {
        var events: [CGEvent] = []
        let executor = SMActionExecutor { events.append($0.copy() ?? $0) }
        var action = SMAction()
        action.kind = .dragScroll

        executor.continuous(action, device: 7, delta: CGPoint(x: 0, y: 12), phase: 1)

        let scroll = try XCTUnwrap(events.first { $0.type == .scrollWheel })
        XCTAssertGreaterThan(scroll.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
    }

    func testSideButtonWheelReversesVerticalDirection() throws {
        var events: [CGEvent] = []
        var timestamp = 1.0
        let executor = SMActionExecutor(eventSink: { events.append($0.copy() ?? $0) }, now: { timestamp }, scheduleTimer: { _, _, _ in nil })
        var action = SMAction()
        action.kind = .wheelQuick
        let input = SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: 8)

        executor.wheel(action, input: input, reverseDirection: true)

        timestamp += 1.0 / 120
        executor.tickWheelScrolling()
        let scroll = try XCTUnwrap(events.first { $0.type == .scrollWheel })
        XCTAssertLessThan(scroll.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
    }

    func testSpeedTiersProduceDistinctAnimatorDistances() throws {
        let values = [SMScrollConfiguration.Speed.low, .medium, .high].map { speed -> Double in
            var dynamics = MMFScrollDynamics(configuration: SMScrollConfiguration(speed: speed))
            return dynamics.distance(input: 36, timestamp: 1)
        }
        XCTAssertEqual(values, [60, 90, 150])
        XCTAssertEqual(Set(values).count, 3)
    }

    func testSmoothnessControlsRuntimeAnimatorAndPhases() throws {
        var configuration = SMScrollConfiguration()
        configuration.smoothness = .off
        XCTAssertNil(configuration.smoothedConfiguration)

        configuration.smoothness = .high
        configuration.trackpadSimulation = false
        XCTAssertEqual(try XCTUnwrap(configuration.smoothedConfiguration).bouncing, false)
        configuration.trackpadSimulation = true
        XCTAssertEqual(try XCTUnwrap(configuration.smoothedConfiguration).bouncing, true)
    }

    func testWheelZoomEmitsCompleteMagnificationGestureSeries() throws {
        var events: [CGEvent] = []
        let executor = SMActionExecutor { events.append($0.copy() ?? $0) }
        var action = SMAction()
        action.kind = .wheelZoom
        let input = SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: 8)

        executor.wheel(action, input: input)
        executor.cancelAll()

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map { $0.getIntegerValueField(CGEventField(rawValue: 132)!) }, [1, 4])
        XCTAssertEqual(events[0].getIntegerValueField(CGEventField(rawValue: 110)!), 8)
        XCTAssertEqual(events[0].getDoubleValueField(CGEventField(rawValue: 113)!), 0.36, accuracy: 0.0001)
        XCTAssertEqual(events[1].getDoubleValueField(CGEventField(rawValue: 113)!), 0, accuracy: 0.0001)
    }

    func testWheelZoomFollowsReversedScrollingDirection() throws {
        var events: [CGEvent] = []
        let executor = SMActionExecutor { events.append($0.copy() ?? $0) }
        var action = SMAction()
        action.kind = .wheelZoom
        let input = SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: 8)

        executor.wheel(action, input: input, reverseZoom: true)
        executor.cancelAll()

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].getDoubleValueField(CGEventField(rawValue: 113)!), -0.36, accuracy: 0.0001)
        XCTAssertEqual(events[1].getDoubleValueField(CGEventField(rawValue: 113)!), 0, accuracy: 0.0001)
    }

    func testSmoothedWheelZoomAnimatesAcrossMultipleFrames() throws {
        var events: [CGEvent] = []
        var timestamp = 1.0
        let executor = SMActionExecutor(
            eventSink: { events.append($0.copy() ?? $0) },
            now: { timestamp },
            scheduleTimer: { _, _, _ in nil }
        )
        let smoothing = Scheme.Scrolling.Smoothed(
            enabled: true,
            preset: .easeInOut,
            response: 0.45,
            speed: 1,
            acceleration: 0,
            inertia: 0.65,
            bouncing: true
        )
        var action = SMAction()
        action.kind = .wheelZoom
        let input = SMInput(device: 7, kind: .wheel, button: 0, time: timestamp, dy: 8)

        executor.wheel(action, input: input, smoothedZoom: smoothing)
        for _ in 0 ..< 120 {
            timestamp += 1.0 / 120.0
            executor.tickZoomAnimations()
        }

        let phases = events.map { $0.getIntegerValueField(CGEventField(rawValue: 132)!) }
        let magnifications = events.map { $0.getDoubleValueField(CGEventField(rawValue: 113)!) }
        XCTAssertGreaterThan(events.count, 10)
        XCTAssertEqual(phases.first, 1)
        XCTAssertEqual(phases.last, 4)
        XCTAssertTrue(phases.dropFirst().dropLast().allSatisfy { $0 == 2 })
        XCTAssertLessThan(abs(magnifications.first ?? 1), 0.1)
        XCTAssertEqual(magnifications.reduce(0, +), 0.396, accuracy: 0.002)
    }

    func testSideButtonZoomSmoothingPreservesTotalMagnification() throws {
        var events: [CGEvent] = []
        var timestamp = 1.0
        let executor = SMActionExecutor(
            eventSink: { events.append($0.copy() ?? $0) },
            now: { timestamp },
            scheduleTimer: { _, _, _ in nil }
        )
        var action = SMAction()
        action.kind = .wheelZoom
        let input = SMInput(device: 7, kind: .wheel, button: 0, time: timestamp, dy: 8)

        executor.wheel(
            action,
            input: input,
            reverseDirection: true,
            smoothedZoom: SMActionExecutor.sideButtonZoomSmoothing
        )
        for _ in 0 ..< 120 {
            timestamp += 1.0 / 120.0
            executor.tickZoomAnimations()
        }

        let magnifications = events.map { $0.getDoubleValueField(CGEventField(rawValue: 113)!) }
        XCTAssertGreaterThan(events.count, 10)
        XCTAssertLessThan(abs(magnifications.first ?? 1), 0.1)
        XCTAssertEqual(magnifications.reduce(0, +), -0.36, accuracy: 0.002)
    }

    func testLaunchpadWheelDirectionGetsExtraDockGestureProgress() throws {
        struct DockEvent {
            var progress: Double
            var velocity: Double
            var motion: Int32
            var phase: Int32
        }
        func capture(_ input: SMInput, actionKind: SMAction.Kind) -> [DockEvent] {
            var events: [DockEvent] = []
            let executor = SMActionExecutor(dockGestureSink: { progress, velocity, motion, phase in
                events.append(.init(progress: progress, velocity: velocity, motion: motion, phase: phase))
                return true
            })
            var action = SMAction()
            action.kind = actionKind
            executor.wheel(action, input: input, reverseDirection: true)
            executor.endWheel(device: input.device)
            return events
        }

        let launchpad = capture(
            SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: -1, physicalWheelSign: -1),
            actionKind: .wheelPinch
        )
        let desktop = capture(
            SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: 1, physicalWheelSign: 1),
            actionKind: .wheelPinch
        )
        let spaces = capture(
            SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: -1, physicalWheelSign: -1),
            actionKind: .wheelSpaces
        )

        let launchpadEvent = try XCTUnwrap(launchpad.first)
        XCTAssertEqual(launchpadEvent.progress, 0.04, accuracy: 0.0001)
        XCTAssertEqual(launchpadEvent.velocity, 4, accuracy: 0.0001)
        XCTAssertEqual(launchpadEvent.motion, 3)
        XCTAssertEqual(launchpadEvent.phase, 1)
        XCTAssertEqual(try XCTUnwrap(desktop.first).progress, -0.025, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(spaces.first).progress, 0.025, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(launchpad.last).progress, 0.04, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(launchpad.last).phase, 4)
        XCTAssertEqual(try XCTUnwrap(desktop.last).progress, -0.025, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(spaces.last).progress, 0.025, accuracy: 0.0001)

    }

    func testRepeatedLaunchpadTicksContinueToAccumulate() {
        var progress: [Double] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { value, _, _, _ in
            progress.append(value); return true
        })
        var action = SMAction(); action.kind = .wheelPinch
        let down = SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: -1, physicalWheelSign: -1)
        for _ in 0 ..< 10 { executor.wheel(action, input: down, reverseDirection: true) }
        XCTAssertEqual(progress.count, 10)
        for (index, value) in progress.enumerated() {
            XCTAssertEqual(value, Double(index + 1) * 0.04, accuracy: 0.0001)
        }
        executor.endWheel(device: 7)
        XCTAssertEqual(progress.last ?? 0, 0.4, accuracy: 0.0001)
    }

    func testOneLaunchpadTickReplaysSuccessfulPhysicalGestureProgress() throws {
        var progress: [Double] = []
        var velocities: [Double] = []
        var phases: [Int32] = []
        var repeatCallback: (() -> Void)?
        var endCallback: (() -> Void)?
        var repeatInterval: TimeInterval = 0
        let executor = SMActionExecutor(scheduleTimer: { interval, repeats, callback in
            if repeats { repeatCallback = callback; repeatInterval = interval }
            else { endCallback = callback }
            return nil
        }, dockGestureSink: { value, velocity, _, phase in
            progress.append(value); velocities.append(velocity); phases.append(phase); return true
        })
        var action = SMAction(); action.kind = .wheelPinch
        executor.wheel(action, input: SMInput(device: 7, kind: .wheel, button: 0, time: 1,
                                              dy: 1, physicalWheelSign: -1), reverseDirection: true)
        let advance = try XCTUnwrap(repeatCallback)
        for _ in 0 ..< 10 { advance() }
        try XCTUnwrap(endCallback)()
        advance()

        // Captured from the user's successful accelerated physical gesture, including its exit speed.
        let recordedProgress = [-0.04, -0.08, -0.28, -0.56, -0.88, -1.24, -1.64, -1.64]
        XCTAssertEqual(progress.count, recordedProgress.count)
        for (actual, recorded) in zip(progress, recordedProgress) {
            XCTAssertEqual(actual, recorded, accuracy: 0.0001)
        }
        XCTAssertEqual(phases, [1, 2, 2, 2, 2, 2, 2, 4])
        XCTAssertEqual(velocities.last ?? 0, -40, accuracy: 0.0001)
        XCTAssertEqual(repeatInterval * 6, 0.09, accuracy: 0.0001)
    }

    func testLaunchpadCompletionPreservesRealInputAndReversesFromFreshOrigin() {
        var progress: [Double] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { value, _, _, _ in
            progress.append(value); return true
        })
        var action = SMAction(); action.kind = .wheelPinch
        let down = SMInput(device: 7, kind: .wheel, button: 0, time: 1, dy: 1, physicalWheelSign: -1)
        executor.wheel(action, input: down, reverseDirection: true)
        executor.wheel(action, input: down, reverseDirection: true)
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress.last ?? 0, -0.08, accuracy: 0.0001)
        executor.tickLaunchpadCompletion(device: 7)
        XCTAssertEqual(progress.last ?? 0, -0.12, accuracy: 0.0001)
        executor.wheel(action, input: SMInput(device: 7, kind: .wheel, button: 0, time: 1.1,
                                              dy: -1, physicalWheelSign: 1), reverseDirection: true)
        XCTAssertEqual(progress.last ?? 0, 0.04, accuracy: 0.0001)
        executor.tickLaunchpadCompletion(device: 7)
        XCTAssertEqual(progress.last ?? 0, 0.08, accuracy: 0.0001)
        executor.cancelAll()
    }

    func testOneReverseTickCompletesReturnWithoutChangingNextDesktopGesture() {
        var progress: [Double] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { value, _, _, _ in
            progress.append(value); return true
        })
        var action = SMAction(); action.kind = .wheelPinch
        executor.wheel(action, input: SMInput(device: 7, kind: .wheel, button: 0, time: 1,
                                              dy: 1, physicalWheelSign: -1), reverseDirection: true)
        for _ in 0 ..< 6 { executor.tickLaunchpadCompletion(device: 7) }
        executor.endWheel(device: 7)
        XCTAssertEqual(progress.last ?? 0, -1.64, accuracy: 0.0001)

        let up = SMInput(device: 7, kind: .wheel, button: 0, time: 2, dy: -1, physicalWheelSign: 1)
        executor.wheel(action, input: up, reverseDirection: true)
        for _ in 0 ..< 6 { executor.tickLaunchpadCompletion(device: 7) }
        executor.endWheel(device: 7)
        XCTAssertEqual(progress.last ?? 0, 1.64, accuracy: 0.0001)

        executor.wheel(action, input: up, reverseDirection: true)
        let beforeTick = progress
        executor.tickLaunchpadCompletion(device: 7)
        XCTAssertEqual(progress, beforeTick)
        XCTAssertEqual(progress.last ?? 0, 0.025, accuracy: 0.0001)
        executor.cancelAll()
    }

    func testManuallyDismissedLaunchpadDoesNotBoostDesktopGesture() {
        var progress: [Double] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { value, _, _, _ in
            progress.append(value); return true
        })
        var action = SMAction(); action.kind = .wheelPinch
        executor.wheel(action, input: SMInput(device: 7, kind: .wheel, button: 0, time: 1,
                                              dy: 1, physicalWheelSign: -1), reverseDirection: true)
        for _ in 0 ..< 6 { executor.tickLaunchpadCompletion(device: 7) }
        executor.endWheel(device: 7)
        executor.clearLaunchpadReturn()
        executor.wheel(action, input: SMInput(device: 7, kind: .wheel, button: 0, time: 2,
                                              dy: -1, physicalWheelSign: 1), reverseDirection: true)
        let beforeTick = progress
        executor.tickLaunchpadCompletion(device: 7)
        XCTAssertEqual(progress, beforeTick)
        XCTAssertEqual(progress.last ?? 0, 0.025, accuracy: 0.0001)
        executor.cancelAll()
    }

    func testLaunchpadCompletionStopsOnCancellationAndOnlyUsesOwningDevice() {
        var phases: [Int32] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { _, _, _, phase in
            phases.append(phase); return true
        })
        var action = SMAction(); action.kind = .wheelPinch
        executor.wheel(action, input: SMInput(device: 7, kind: .wheel, button: 0, time: 1,
                                              dy: 1, physicalWheelSign: -1), reverseDirection: true)
        executor.tickLaunchpadCompletion(device: 8)
        XCTAssertEqual(phases, [1])
        executor.cancelAll()
        executor.tickLaunchpadCompletion(device: 7)
        XCTAssertEqual(phases, [1, 4])
    }

    func testChromiumWheelZoomAddsResponsiveChangedEvent() throws {
        var events: [CGEvent] = []
        let executor = SMActionExecutor { events.append($0.copy() ?? $0) }
        var action = SMAction()
        action.kind = .wheelZoom
        let input = SMInput(
            device: 7,
            kind: .wheel,
            button: 0,
            time: 1,
            dy: 1,
            app: "com.google.Chrome.canary"
        )

        executor.wheel(action, input: input)
        executor.cancelAll()

        XCTAssertEqual(events.map { $0.getIntegerValueField(CGEventField(rawValue: 132)!) }, [1, 2, 4])
        XCTAssertEqual(events[1].getDoubleValueField(CGEventField(rawValue: 113)!), 0.52, accuracy: 0.0001)
    }
}

final class SMGestureStyleTests: XCTestCase {
    func testSpecialShortcutLabelsUseReadableKeys() {
        var action = SMAction()
        action.kind = .shortcut
        action.keyCode = 0x73
        action.modifiers = CGEventFlags.maskCommand.rawValue
        action.shortcutLabel = "⌘\u{F729}"

        XCTAssertEqual(action.resolvedShortcutLabel, "⌘Home")
        XCTAssertEqual(
            SMAction.formattedShortcutLabel(
                keyCode: 0x7B,
                modifiers: CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue,
                fallbackKey: "\u{F702}"
            ),
            "⌃⌥←"
        )
    }

    func testDefaultOrBlankRuleNameUsesActionLabel() {
        var rule = SMRule()
        rule.action.kind = .wheelZoom
        XCTAssertFalse(rule.hasCustomName)
        XCTAssertEqual(rule.displayName, "放大或缩小")

        rule.name = "   "
        XCTAssertFalse(rule.hasCustomName)
        XCTAssertEqual(rule.displayName, "放大或缩小")

        rule.name = "我的缩放"
        XCTAssertTrue(rule.hasCustomName)
        XCTAssertEqual(rule.displayName, "我的缩放")
    }

    func testLegacyRulesDecodeWithDefaultTrailStyle() throws {
        let data = try XCTUnwrap(
            """
            {
              "version": 1,
              "rules": [],
              "trailThreshold": 18,
              "holdDelay": 0.45,
              "clickInterval": 0.3,
              "showTrail": true
            }
            """.data(using: .utf8)
        )

        let configuration = try JSONDecoder().decode(SMConfiguration.self, from: data).validated()

        XCTAssertEqual(configuration.resolvedTrailWidth, 4)
        XCTAssertEqual(configuration.resolvedTrailColorHex, "007AFFD9")
        XCTAssertTrue(configuration.resolvedShowGestureLabel)
        XCTAssertEqual(configuration.resolvedGestureLabelFontSize, 36)
        XCTAssertEqual(configuration.resolvedGestureLabelColorHex, "FFFFFFFF")
        XCTAssertEqual(configuration.resolvedGestureLabelBackgroundColorHex, "000000B8")
        XCTAssertEqual(configuration.resolvedGestureLabelPosition, .center)
    }

    func testTrailStyleRoundTripsThroughConfiguration() throws {
        var configuration = SMConfiguration()
        configuration.trailWidth = 9
        configuration.trailColorHex = "FF3366A0"
        configuration.showGestureLabel = false
        configuration.gestureLabelFontSize = 31
        configuration.gestureLabelColorHex = "102030FF"
        configuration.gestureLabelBackgroundColorHex = "F0E0D0C0"
        configuration.gestureLabelPosition = .topRight

        let data = try JSONEncoder().encode(configuration.validated())
        let decoded = try JSONDecoder().decode(SMConfiguration.self, from: data).validated()

        XCTAssertEqual(decoded.resolvedTrailWidth, 9)
        XCTAssertEqual(decoded.resolvedTrailColorHex, "FF3366A0")
        XCTAssertFalse(decoded.resolvedShowGestureLabel)
        XCTAssertEqual(decoded.resolvedGestureLabelFontSize, 31)
        XCTAssertEqual(decoded.resolvedGestureLabelColorHex, "102030FF")
        XCTAssertEqual(decoded.resolvedGestureLabelBackgroundColorHex, "F0E0D0C0")
        XCTAssertEqual(decoded.resolvedGestureLabelPosition, .topRight)
    }

    func testTrailColorConversionPreservesRGBA() throws {
        let color = try XCTUnwrap(NSColor(smHex: "12AB34C8"))
        XCTAssertEqual(color.smHex, "12AB34C8")
    }

    func testDefaultSideButtonsAreAddedAlongsideExistingGestures() throws {
        var configuration = SMConfiguration()
        var gesture = SMRule()
        gesture.trigger.button = 1
        gesture.trigger.kind = .trail
        configuration.rules = [gesture]

        configuration.installDefaultSideButtonRulesIfNeeded()

        let sideRules = Array(configuration.rules.dropFirst())
        XCTAssertEqual(sideRules.count, 8)
        XCTAssertEqual(sideRules.filter { $0.trigger.button == 3 }.map(\.trigger.kind), [.click, .wheelUp, .wheelDown, .drag])
        XCTAssertEqual(sideRules.filter { $0.trigger.button == 4 }.map(\.trigger.kind), [.click, .wheelUp, .wheelDown, .drag])
        XCTAssertEqual(sideRules[0].action.builtin, "lookUpAndDataDetectors")
        XCTAssertEqual(sideRules[1].action.kind, .wheelPinch)
        XCTAssertEqual(sideRules[2].action.kind, .wheelPinch)
        XCTAssertEqual(sideRules[3].action.kind, .dragSpaces)
        XCTAssertEqual(sideRules[4].action.builtin, "smartZoom")
        XCTAssertEqual(sideRules[5].action.kind, .wheelZoom)
        XCTAssertEqual(sideRules[6].action.kind, .wheelZoom)
        XCTAssertEqual(sideRules[7].action.kind, .dragScroll)
        XCTAssertNoThrow(try configuration.validated())
    }
}
