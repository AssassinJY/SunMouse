import XCTest
@testable import SunMouse

final class SMInterpreterTests: XCTestCase {
    func input(_ kind: SMInput.Kind, device: Int32 = 1, button: Int = 1, time: Double = 0, x: Double = 0, y: Double = 0, dy: Double = 0, app: String = "browser") -> SMInput {
        SMInput(device: device, kind: kind, button: button, time: time, point: CGPoint(x: x, y: y), dy: dy, app: app)
    }
    func rule(_ kind: SMTrigger.Kind, button: Int = 1, clicks: Int = 1, path: String = "R") -> SMRule {
        var r = SMRule(); r.trigger.kind = kind; r.trigger.button = button; r.trigger.clicks = clicks; r.trigger.path = path
        return r
    }
    func config(_ rules: [SMRule]) -> SMConfiguration { var c = SMConfiguration(); c.rules = rules; return c }
    func actions(_ result: SMDecision) -> [SMRule] { result.effects.compactMap { if case let .action(rule, _) = $0 { return rule }; return nil } }
    func trailLabels(_ result: SMDecision) -> [String] {
        result.effects.compactMap { if case let .trail(_, _, label) = $0 { return label }; return nil }
    }
    func testNoRulePassesThrough() {
        XCTAssertFalse(SMInterpreter().process(input(.down), configuration: config([])).consume)
    }
    func testGestureSwitchDefaultsOnAndPersists() throws {
        var c = config([rule(.click)])
        XCTAssertTrue(c.resolvedGesturesEnabled)
        c.gesturesEnabled = false
        let decoded = try JSONDecoder().decode(SMConfiguration.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(decoded.resolvedGesturesEnabled)
    }

    func testDisabledGesturesPassThroughWhileSideButtonsStillWork() {
        var c = config([rule(.click), rule(.click, button: 3)])
        c.gesturesEnabled = false
        let e = SMInterpreter()
        XCTAssertFalse(e.process(input(.down), configuration: c).consume)
        XCTAssertFalse(e.process(input(.down, button: 2), configuration: c).consume)
        XCTAssertTrue(e.process(input(.down, button: 3), configuration: c).consume)
        XCTAssertEqual(actions(e.process(input(.up, button: 3, time: 0.1), configuration: c)).count, 1)
    }

    func testGestureCancellationPreservesSideButtonSession() {
        let c = config([rule(.trail), rule(.click, button: 3)])
        let e = SMInterpreter()
        _ = e.process(input(.down), configuration: c)
        _ = e.process(input(.down, button: 3), configuration: c)
        _ = e.cancel(gesturesOnly: true)
        XCTAssertEqual(e.activeCount, 1)
        XCTAssertEqual(actions(e.process(input(.up, button: 3, time: 0.1), configuration: c)).count, 1)
    }
    func testSideButtonSwitchDefaultsOnAndPersists() throws {
        var c = try JSONDecoder().decode(SMConfiguration.self, from: JSONEncoder().encode(config([])))
        XCTAssertTrue(c.resolvedSideButtonsEnabled)
        c.sideButtonsEnabled = false
        let decoded = try JSONDecoder().decode(SMConfiguration.self, from: JSONEncoder().encode(c))
        XCTAssertFalse(decoded.resolvedSideButtonsEnabled)
    }

    func testDisabledSideButtonsPassThroughWhileGesturesStillWork() {
        var c = config([rule(.click), rule(.click, button: 3), rule(.click, button: 4)])
        c.sideButtonsEnabled = false
        let e = SMInterpreter()
        for button in [3, 4] {
            XCTAssertFalse(e.process(input(.down, button: button), configuration: c).consume)
            XCTAssertFalse(e.process(input(.up, button: button, time: 0.1), configuration: c).consume)
        }
        XCTAssertTrue(e.process(input(.down, time: 0.2), configuration: c).consume)
        XCTAssertEqual(actions(e.process(input(.up, time: 0.3), configuration: c)).count, 1)
    }

    func testSideButtonCancellationPreservesGestureSession() {
        let c = config([rule(.click), rule(.hold, button: 3)])
        let e = SMInterpreter()
        _ = e.process(input(.down), configuration: c)
        _ = e.process(input(.down, button: 3), configuration: c)
        _ = e.cancel(sideButtonsOnly: true)
        XCTAssertEqual(e.activeCount, 1)
        XCTAssertTrue(actions(e.tick(1)).isEmpty)
        XCTAssertEqual(actions(e.process(input(.up, time: 1.1), configuration: c)).count, 1)
        XCTAssertFalse(e.process(input(.up, button: 3, time: 1.2), configuration: c).consume)
    }

    func testApplicationExclusionPassesDownThrough() {
        var r = rule(.click); r.filter = SMAppFilter(mode: .except, applications: ["browser"])
        XCTAssertFalse(SMInterpreter().process(input(.down), configuration: config([r])).consume)
    }
    func testClickWaitsForRelease() {
        let e = SMInterpreter(), c = config([rule(.click)])
        XCTAssertTrue(e.process(input(.down), configuration: c).consume)
        XCTAssertEqual(actions(e.process(input(.up, time: 0.1), configuration: c)).count, 1)
        XCTAssertEqual(e.activeCount, 0)
    }
    func testDoubleClickSuppressesSingle() {
        let e = SMInterpreter(), single = rule(.click), double = rule(.click, clicks: 2), c = config([single, double])
        _ = e.process(input(.down), configuration: c)
        XCTAssertTrue(actions(e.process(input(.up, time: 0.05), configuration: c)).isEmpty)
        _ = e.process(input(.down, time: 0.1), configuration: c)
        XCTAssertEqual(actions(e.process(input(.up, time: 0.15), configuration: c)).map(\.id), [double.id])
        XCTAssertTrue(actions(e.tick(1)).isEmpty)
    }
    func testSingleAfterDoubleDeadline() {
        let e = SMInterpreter(), single = rule(.click), c = config([single, rule(.click, clicks: 2)])
        _ = e.process(input(.down), configuration: c); _ = e.process(input(.up, time: 0.05), configuration: c)
        XCTAssertEqual(actions(e.tick(0.4)).map(\.id), [single.id])
    }
    func testTripleClick() {
        let e = SMInterpreter(), triple = rule(.click, clicks: 3), c = config([rule(.click), rule(.click, clicks: 2), triple])
        for t in [0.0, 0.1] { _ = e.process(input(.down, time: t), configuration: c); XCTAssertTrue(actions(e.process(input(.up, time: t + 0.04), configuration: c)).isEmpty) }
        _ = e.process(input(.down, time: 0.2), configuration: c)
        XCTAssertEqual(actions(e.process(input(.up, time: 0.24), configuration: c)).map(\.id), [triple.id])
    }
    func testHoldDoesNotClickOnRelease() {
        let e = SMInterpreter(), hold = rule(.hold), c = config([rule(.click), hold])
        _ = e.process(input(.down), configuration: c)
        XCTAssertEqual(actions(e.tick(0.5)).map(\.id), [hold.id])
        XCTAssertTrue(actions(e.process(input(.up, time: 0.6), configuration: c)).isEmpty)
    }
    func testTrailSuppressesClick() {
        let e = SMInterpreter(), trail = rule(.trail, path: "RD"), c = config([rule(.click), trail])
        _ = e.process(input(.down), configuration: c)
        _ = e.process(input(.move, time: 0.1, x: 40), configuration: c)
        _ = e.process(input(.move, time: 0.2, x: 40, y: 40), configuration: c)
        XCTAssertEqual(actions(e.process(input(.up, time: 0.3, x: 40, y: 40), configuration: c)).map(\.id), [trail.id])
    }
    func testTrailPublishesMatchedRuleName() {
        var trail = rule(.trail, path: "R")
        trail.name = "向右操作"
        let e = SMInterpreter(), c = config([trail])
        _ = e.process(input(.down), configuration: c)

        XCTAssertEqual(trailLabels(e.process(input(.move, time: 0.1, x: 40), configuration: c)), ["向右操作"])
    }
    func testTrailUsesRuleNameInsteadOfActionLabel() {
        var trail = rule(.trail, path: "R")
        trail.name = "复制"
        trail.action.shortcutLabel = "⌘C"
        let e = SMInterpreter(), c = config([trail])
        _ = e.process(input(.down), configuration: c)

        XCTAssertEqual(trailLabels(e.process(input(.move, time: 0.1, x: 40), configuration: c)), ["复制"])
    }
    func testUnknownTrailDoesNotFireClick() {
        let e = SMInterpreter(), c = config([rule(.click), rule(.trail, path: "U")])
        _ = e.process(input(.down), configuration: c); _ = e.process(input(.move, time: 0.1, x: 50), configuration: c)
        XCTAssertTrue(actions(e.process(input(.up, time: 0.2), configuration: c)).isEmpty)
    }
    func testDeviceBWheelCannotUseDeviceARightButton() {
        let e = SMInterpreter(), c = config([rule(.wheelUp)])
        _ = e.process(input(.down, device: 1), configuration: c)
        XCTAssertFalse(e.process(input(.wheel, device: 2, time: 0.1, dy: 1), configuration: c).consume)
        XCTAssertEqual(actions(e.process(input(.wheel, device: 1, time: 0.1, dy: 1), configuration: c)).count, 1)
    }
    func testDeviceBMovementCannotAdvanceDeviceATrail() {
        let e = SMInterpreter(), c = config([rule(.trail)])
        _ = e.process(input(.down), configuration: c)
        XCTAssertFalse(e.process(input(.move, device: 2, time: 0.1, x: 80), configuration: c).consume)
        XCTAssertTrue(actions(e.process(input(.up, time: 0.2), configuration: c)).isEmpty)
    }
    func testWheelSuppressesClickAndRateLimits() {
        let e = SMInterpreter(), c = config([rule(.click), rule(.wheelUp)])
        _ = e.process(input(.down), configuration: c)
        XCTAssertEqual(actions(e.process(input(.wheel, time: 0.1, dy: 1), configuration: c)).count, 1)
        XCTAssertTrue(actions(e.process(input(.wheel, time: 0.11, dy: 1), configuration: c)).isEmpty)
        XCTAssertTrue(actions(e.process(input(.up, time: 0.2), configuration: c)).isEmpty)
    }
    func testFilterPriorityAndOriginalAppAreFrozen() {
        let global = rule(.click); var specific = rule(.click); specific.filter = SMAppFilter(mode: .only, applications: ["browser"])
        let e = SMInterpreter(), c = config([global, specific])
        _ = e.process(input(.down), configuration: c)
        XCTAssertEqual(actions(e.process(input(.up, time: 0.1, app: "editor"), configuration: c)).map(\.id), [specific.id])
    }
    func testRuleChangesDoNotChangeActiveInteraction() {
        let original = rule(.click), changed = rule(.click), e = SMInterpreter()
        _ = e.process(input(.down), configuration: config([original]))
        XCTAssertEqual(actions(e.process(input(.up, time: 0.1), configuration: config([changed]))).map(\.id), [original.id])
    }
    func testHeldPrefixIsConsumedByChord() {
        var chord = rule(.click, button: 4); chord.trigger.held = [.init(button: 3)]
        let prefix = rule(.click, button: 3), e = SMInterpreter(), c = config([prefix, chord])
        _ = e.process(input(.down, button: 3), configuration: c)
        _ = e.process(input(.down, button: 4, time: 0.05), configuration: c)
        XCTAssertEqual(actions(e.process(input(.up, button: 4, time: 0.1), configuration: c)).map(\.id), [chord.id])
        XCTAssertTrue(actions(e.process(input(.up, button: 3, time: 0.15), configuration: c)).isEmpty)
    }
    func testCancelRemovesAllDeviceState() {
        let e = SMInterpreter(), c = config([rule(.hold)])
        _ = e.process(input(.down), configuration: c); _ = e.process(input(.down, device: 2), configuration: c)
        _ = e.cancel(device: 1); XCTAssertEqual(e.activeCount, 1)
        _ = e.cancel(); XCTAssertEqual(e.activeCount, 0); XCTAssertTrue(actions(e.tick(2)).isEmpty)
    }
    func testInvalidImportRejected() {
        var c = config([rule(.click)]); c.rules[0].trigger.clicks = 0
        XCTAssertThrowsError(try c.validated())
        c = config([rule(.click)]); c.version = 999; XCTAssertThrowsError(try c.validated())
    }
    func testWheelShortcutDoesNotRequireHiddenTrailPath() {
        for kind in [SMTrigger.Kind.wheelUp, .wheelDown, .click] {
            var r = rule(kind, button: 1, path: "")
            r.filter = SMAppFilter(mode: .only, applications: ["com.google.Chrome"])
            XCTAssertNoThrow(try config([r]).validated())
        }
    }
    func testTrailStillRequiresValidDirections() {
        for path in ["", "X", String(repeating: "R", count: 33)] {
            XCTAssertThrowsError(try config([rule(.trail, button: 1, path: path)]).validated())
        }
        XCTAssertNoThrow(try config([rule(.trail, button: 1, path: "RU")]).validated())
    }
    func testModifiersExactMatchAndDisable() {
        var m = SMScrollModifiers()
        XCTAssertEqual(m.kind(for: CGEventFlags.maskShift.rawValue), .wheelHorizontal)
        XCTAssertEqual(m.kind(for: CGEventFlags.maskCommand.rawValue), .wheelZoom)
        XCTAssertNil(m.kind(for: CGEventFlags([.maskShift, .maskCommand]).rawValue))
        m.horizontal = 0; XCTAssertNil(m.kind(for: 0))
    }
    func testHeldPrefixCanReleaseBeforeMainButton() {
        var r = rule(.click, button: 4); r.trigger.held = [.init(button: 3)]
        let e = SMInterpreter(), c = config([rule(.click, button: 3), r])
        _ = e.process(input(.down, button: 3), configuration: c)
        _ = e.process(input(.down, button: 4, time: 0.1), configuration: c)
        XCTAssertTrue(actions(e.process(input(.up, button: 3, time: 0.2), configuration: c)).isEmpty)
        XCTAssertEqual(actions(e.process(input(.up, button: 4, time: 0.3), configuration: c)).map(\.id), [r.id])
    }
    func testUnidentifiedReleaseCannotLeaveHoldTimerRunning() {
        let e = SMInterpreter(), c = config([rule(.hold)])
        _ = e.process(input(.down), configuration: c)
        _ = e.cancelUnidentifiedRelease(button: 1)
        XCTAssertTrue(actions(e.tick(2)).isEmpty)
        XCTAssertEqual(e.activeCount, 0)
    }
    func testPhysicalWheelDirectionIgnoresNaturalScrolling() {
        let r = rule(.wheelUp), e = SMInterpreter(), c = config([r])
        _ = e.process(input(.down), configuration: c)
        var wheel = input(.wheel, time: 0.1, dy: -1); wheel.physicalWheelSign = 1
        XCTAssertEqual(actions(e.process(wheel, configuration: c)).map(\.id), [r.id])
    }
    func testHighResolutionWheelFallsBackToPixelDelta() {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 2)
        XCTAssertEqual(SMRuntime.wheelDelta(event), 0.2, accuracy: 0.001)
    }
    func testExactDeviceLookupNeverFallsBackToAnotherMouse() {
        final class Mouse {}
        let snapshot = EventDeviceSnapshot<Mouse>(), a = Mouse(), b = Mouse()
        snapshot.replaceDevices([1: a, 2: b]); snapshot.setLastActiveDevice(a)
        XCTAssertTrue(snapshot.exactDevice(for: 2) === b)
        XCTAssertNil(snapshot.exactDevice(for: 999))
    }

}
