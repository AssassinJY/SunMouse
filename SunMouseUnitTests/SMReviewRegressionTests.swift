import XCTest
@testable import SunMouse

final class SMRuleStoreRecoveryTests: XCTestCase {
    private var directory: URL!
    private var rulesURL: URL { directory.appendingPathComponent("rules.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUnreadableRulesAreNotOverwrittenOnLaunch() throws {
        let original = Data("{incomplete user rules".utf8)
        try original.write(to: rulesURL)
        let store = SMRuleStore(url: rulesURL)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try Data(contentsOf: rulesURL), original)
        XCTAssertTrue(store.snapshot().rules.isEmpty)
    }

    func testInvalidRulesAreNotOverwrittenOnLaunch() throws {
        var config = SMConfiguration()
        config.version = 99
        let original = try JSONEncoder().encode(config)
        try original.write(to: rulesURL)
        let store = SMRuleStore(url: rulesURL)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(try Data(contentsOf: rulesURL), original)
    }

    func testExplicitEditBacksUpUnreadableRulesBeforeSaving() throws {
        let original = Data("unreadable user rules".utf8)
        try original.write(to: rulesURL)
        let store = SMRuleStore(url: rulesURL)
        var updated = SMConfiguration()
        updated.installDefaultSideButtonRulesIfNeeded()
        store.configuration = updated
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshot(), updated)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("rules-unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        XCTAssertEqual(try JSONDecoder().decode(SMConfiguration.self, from: Data(contentsOf: rulesURL)), updated)
    }

    func testFailedRecoveryBackupKeepsExistingFileAndSnapshot() throws {
        // A directory where a JSON file should be makes the initial read fail.
        try FileManager.default.createDirectory(at: rulesURL, withIntermediateDirectories: true)
        let store = SMRuleStore(url: rulesURL)
        // Remove the unreadable path to simulate it becoming unavailable before backup.
        try FileManager.default.removeItem(at: rulesURL)
        store.configuration.installDefaultSideButtonRulesIfNeeded()
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesURL.path))
        XCTAssertTrue(store.snapshot().rules.isEmpty)
    }

    func testFirstLaunchUsesBundledConfigurationTemplate() throws {
        let store = SMRuleStore(url: rulesURL)
        let template = try SMDefaultConfiguration.load()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshot(), template.rules)
        XCTAssertTrue(store.snapshot().rules.contains { $0.trigger.kind == .trail })
        XCTAssertTrue(store.snapshot().rules.contains { $0.trigger.button >= 3 })
        XCTAssertFalse(template.devices.schemes.isEmpty)
        let devices = try Configuration.load(from: template.devices.dump())
        XCTAssertEqual(devices, template.devices)
        XCTAssertEqual(try JSONDecoder().decode(SMConfiguration.self, from: Data(contentsOf: rulesURL)), store.snapshot())
    }

    func testExistingConfigurationIsPreservedInsteadOfApplyingTemplate() throws {
        var config = SMConfiguration()
        config.installDefaultSideButtonRulesIfNeeded()
        config.showTrail = false
        let original = try JSONEncoder().encode(config)
        try original.write(to: rulesURL)
        let store = SMRuleStore(url: rulesURL)
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshot(), config)
        XCTAssertEqual(try Data(contentsOf: rulesURL), original)
    }
}

final class SMConfigurationSnapshotTests: XCTestCase {
    func testSnapshotIsUpdatedBeforePublishedSubscribersInvalidateRoutes() {
        let state = ConfigurationState()
        var observedSnapshots: [Configuration] = []
        let subscription = state.$configuration.sink { configuration in
            observedSnapshots.append(state.snapshot())
            XCTAssertEqual(state.snapshot(), configuration)
        }
        var updated = Configuration()
        updated.schemes = [Scheme()]
        state.configuration = updated
        XCTAssertEqual(observedSnapshots, [Configuration(), updated])
        XCTAssertEqual(state.snapshot(), updated)
        withExtendedLifetime(subscription) {}
    }
}

final class SMDeviceAnimationCleanupTests: XCTestCase {
    func testDeviceCancellationStopsLaunchpadCompletionAndReleasesDockOwner() {
        var phases: [Int32] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { _, _, _, phase in
            phases.append(phase)
            return true
        })
        var action = SMAction()
        action.kind = .wheelPinch
        executor.wheel(action, input: .init(device: 7, kind: .wheel, button: 0, time: 1, dy: 1, physicalWheelSign: -1))
        executor.cancel(device: 7)
        executor.tickLaunchpadCompletion(device: 7)
        XCTAssertEqual(phases, [1, 4])
        action.kind = .dragSpaces
        executor.continuous(action, device: 8, delta: CGPoint(x: 30, y: 0), phase: 1)
        XCTAssertEqual(phases, [1, 4, 1])
        executor.cancelAll()
    }

    func testUnrelatedDeviceCancellationPreservesDockGesture() {
        var phases: [Int32] = []
        let executor = SMActionExecutor(scheduleTimer: { _, _, _ in nil }, dockGestureSink: { _, _, _, phase in
            phases.append(phase)
            return true
        })
        var action = SMAction()
        action.kind = .dragSpaces
        executor.continuous(action, device: 8, delta: CGPoint(x: 30, y: 0), phase: 1)
        executor.cancel(device: 7)
        executor.continuous(action, device: 8, delta: CGPoint(x: 10, y: 0), phase: 2)
        XCTAssertEqual(phases, [1, 2])
        executor.cancelAll()
    }

    func testDeviceCancellationStopsOnlyItsWheelScroller() {
        var events: [CGEvent] = []
        var timestamp = 1.0
        let executor = SMActionExecutor(eventSink: { events.append($0) }, now: { timestamp }, scheduleTimer: { _, _, _ in nil })
        var action = SMAction()
        action.kind = .wheelQuick
        for device: Int32 in [7, 8] {
            executor.wheel(action, input: .init(device: device, kind: .wheel, button: 0, time: 1, dy: 8))
        }
        executor.cancel(device: 7)
        timestamp += 1.0 / 120
        executor.tickWheelScrolling()
        XCTAssertFalse(events.isEmpty)
        executor.cancel(device: 8)
        let count = events.count
        timestamp += 1.0 / 120
        executor.tickWheelScrolling()
        XCTAssertEqual(events.count, count)
    }

    func testDeviceCancellationStopsSmoothedZoom() {
        var events: [CGEvent] = []
        var timestamp = 1.0
        let executor = SMActionExecutor(eventSink: { events.append($0) }, now: { timestamp }, scheduleTimer: { _, _, _ in nil })
        var action = SMAction()
        action.kind = .wheelZoom
        executor.wheel(action, input: .init(device: 7, kind: .wheel, button: 0, time: 1, dy: 8),
                       smoothedZoom: SMActionExecutor.sideButtonZoomSmoothing)
        timestamp += 1.0 / 120
        executor.tickZoomAnimations()
        XCTAssertFalse(events.isEmpty)
        executor.cancel(device: 7)
        let count = events.count
        timestamp += 1.0 / 120
        executor.tickZoomAnimations()
        XCTAssertEqual(events.count, count)
        executor.cancelAll()
    }
}
