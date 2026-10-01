import AppKit
import GestureKit
import os.log

final class SMRuntime {
    static let shared = SMRuntime()
    static let marker: Int64 = 0x53554E4D4F555345
    static let preciseMarker: Int64 = marker + 1
    static let quickMarker: Int64 = marker + 2
    let interpreter = SMInterpreter()
    private var scrollKinds: [Int32: SMAction.Kind] = [:]
    private var timer: EventThreadTimer?
    private var appObserver: NSObjectProtocol?
    private let appLock = NSLock()
    private var frontApp = ""
    private var actions = SMActionExecutor()
    private var initialized = false
    func prepare() {
        guard !initialized else { return }; initialized = true
        _ = SMRuleStore.shared
        updateApp()
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.updateApp() }
    }
    private func updateApp() {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        appLock.lock(); frontApp = app; appLock.unlock()
    }
    static func shouldProcess(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == marker { return false }
        if event.isSunMouseSyntheticEvent {
            return [.otherMouseDown, .otherMouseUp].contains(event.type)
        }
        return true
    }
    func observeLaunchpadDismissal(_ event: CGEvent) {
        guard Self.shouldProcess(event) else { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown ||
            (event.type == .keyDown && [36, 48, 53, 76].contains(event.getIntegerValueField(.keyboardEventKeycode))) {
            actions.clearLaunchpadReturn()
        }
    }
    func transform(_ event: CGEvent, device: Device) -> CGEvent? {
        guard Self.shouldProcess(event) else { return event }
        cancelDisabledRules()
        let kind: SMInput.Kind
        switch event.type {
        case .rightMouseDown, .otherMouseDown: kind = .down
        case .rightMouseUp, .otherMouseUp: kind = .up
        case .rightMouseDragged, .otherMouseDragged, .mouseMoved: kind = .move
        case .scrollWheel: kind = .wheel
        default: return event
        }
        if kind == .move && interpreter.activeCount == 0 { return event }
        appLock.lock(); let app = frontApp; appLock.unlock()
        var input = SMInput(device: device.id, kind: kind, button: Int(event.getIntegerValueField(.mouseEventButtonNumber)),
                            time: ProcessInfo.processInfo.systemUptime, point: event.location,
                            dx: kind == .wheel ? event.getDoubleValueField(.scrollWheelEventDeltaAxis2) : Double(event.getIntegerValueField(.mouseEventDeltaX)),
                            dy: kind == .wheel ? Self.wheelDelta(event) : Double(event.getIntegerValueField(.mouseEventDeltaY)),
                            modifiers: event.flags.rawValue & SMConfiguration.modifierMask, app: app, original: event.copy())
        if kind == .wheel {
            let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
            input.physicalWheelSign = (input.dy > 0 ? 1 : -1) * (inverted ? -1 : 1)
        }
        let decision = interpreter.process(input, configuration: SMRuleStore.shared.snapshot())
        if decision.consume { SmoothedScrollingTransformer.interrupt(device: device.id) }
        deliver(decision)
        if interpreter.activeCount > 0 && timer == nil {
            timer = EventThread.shared.scheduleTimer(interval: 0.02, repeats: true) { [weak self] in
                guard let self else { return }
                self.cancelDisabledRules()
                self.deliver(self.interpreter.tick(ProcessInfo.processInfo.systemUptime))
                if self.interpreter.activeCount == 0 { self.timer?.invalidate(); self.timer = nil }
            }
        }
        if decision.consume { return nil }
        if kind == .wheel {
            let scheme = ConfigurationState.shared.snapshot().matchScheme(withDevice: device, withApp: nil)
            let selected = (scheme.scrolling.sunModifiers ?? SMScrollModifiers()).kind(for: input.modifiers)
            if selected != scrollKinds[device.id] { SmoothedScrollingTransformer.interrupt(device: device.id) }
            scrollKinds[device.id] = selected
            if let selected {
                event.flags = CGEventFlags(rawValue: event.flags.rawValue & ~SMConfiguration.modifierMask)
                if selected == .wheelZoom {
                    var action = SMAction(); action.kind = selected
                    actions.wheel(
                        action,
                        input: input,
                        reverseZoom: scheme.scrolling.reverse.vertical == true,
                        smoothedZoom: scheme.scrolling.resolvedSunScroll.smoothedConfiguration
                    )
                    return nil
                }
                if selected == .wheelHorizontal { Self.makeHorizontal(event) }
                if selected == .wheelQuick || selected == .wheelPrecise {
                    // Pass the mode to the animator; do not scale accelerated line
                    // fields or bypass the dedicated precise-scroll curve.
                    event.setIntegerValueField(.eventSourceUserData,
                                               value: selected == .wheelQuick ? Self.quickMarker : Self.preciseMarker)
                }
            }
        }
        return event
    }
    static func makeHorizontal(_ event: CGEvent) {
        let view = ScrollWheelEventView(event)
        // Shift-scroll may already arrive on X. Never turn it back into vertical scrolling.
        if view.deltaY != 0 || view.deltaYPt != 0 || view.deltaYFixedPt != 0 {
            view.swapXY()
        }
    }
    static func wheelDelta(_ event: CGEvent) -> Double {
        let line = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        if line != 0 { return line }
        let point = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        if point != 0 { return point / 10 }
        return event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
    }
    func unidentified(_ event: CGEvent) {
        if [.rightMouseUp, .otherMouseUp].contains(event.type) {
            deliver(interpreter.cancelUnidentifiedRelease(button: Int(event.getIntegerValueField(.mouseEventButtonNumber))))
        }
    }
    func cancel(device: Int32? = nil) {
        deliver(interpreter.cancel(device: device))
        if interpreter.activeCount == 0 { timer?.invalidate(); timer = nil }
        if let device {
            scrollKinds.removeValue(forKey: device)
            actions.cancel(device: device)
        } else {
            scrollKinds.removeAll()
            actions.cancelAll()
        }
    }
    private func cancelDisabledRules() {
        let configuration = SMRuleStore.shared.snapshot()
        if !configuration.resolvedSideButtonsEnabled {
            deliver(interpreter.cancel(sideButtonsOnly: true))
        }
        if !configuration.resolvedGesturesEnabled {
            deliver(interpreter.cancel(gesturesOnly: true))
        }
    }
    private func deliver(_ decision: SMDecision) {
        for effect in decision.effects {
            switch effect {
            case let .replay(inputs):
                for input in inputs { if let e = input.original { e.setIntegerValueField(.eventSourceUserData, value: Self.marker); e.post(tap: .cgSessionEventTap) } }
            case let .action(rule, app): actions.perform(rule.action, app: app)
            case let .continuous(action, device, delta, phase): actions.continuous(action, device: device, delta: delta, phase: phase)
            case let .wheel(action, input):
                actions.wheel(
                    action,
                    input: input,
                    reverseDirection: true,
                    smoothedZoom: action.kind == .wheelZoom ? SMActionExecutor.sideButtonZoomSmoothing : nil
                )
            case let .trail(device, points, label):
                let configuration = SMRuleStore.shared.snapshot()
                DispatchQueue.main.async {
                    SMTrailOverlay.shared.show(
                        device: device,
                        points: points,
                        width: configuration.resolvedTrailWidth,
                        colorHex: configuration.resolvedTrailColorHex,
                        showTrail: configuration.showTrail,
                        label: configuration.resolvedShowGestureLabel ? label : nil,
                        labelFontSize: configuration.resolvedGestureLabelFontSize,
                        labelColorHex: configuration.resolvedGestureLabelColorHex,
                        labelBackgroundColorHex: configuration.resolvedGestureLabelBackgroundColorHex,
                        labelPosition: configuration.resolvedGestureLabelPosition
                    )
                }
            case let .hideTrail(device): DispatchQueue.main.async { SMTrailOverlay.shared.hide(device: device) }
            }
        }
    }
}

final class SMActionExecutor {
    typealias TimerScheduler = (TimeInterval, Bool, @escaping () -> Void) -> EventThreadTimer?
    typealias DockGestureSink = (Double, Double, Int32, Int32) -> Bool

    static let sideButtonZoomSmoothing = Scheme.Scrolling.Smoothed(
        enabled: true,
        preset: .easeOut,
        response: 0.90,
        speed: 0.714285714,
        acceleration: 0,
        inertia: 0.35,
        bouncing: true
    )

    private static let pinchLog = OSLog(subsystem: "local.sun.SunMouse", category: "PinchGesture")
    private let executor = ButtonActionExecutor()
    private let eventSink: (CGEvent) -> Void
    private let now: () -> TimeInterval
    private let scheduleTimer: TimerScheduler
    private let dockGestureSink: DockGestureSink
    private struct Motion { var action: SMAction; var origin: Double = 0; var last: Double = 0; var axis: Int = 0 }
    private struct ZoomAnimation {
        var configuration: Scheme.Scrolling.Smoothed
        var engine: SmoothedScrollingEngine
        var app: String
        var hasBegun = false
    }
    private var motions: [Int32: Motion] = [:]
    private var wheelEnd: [Int32: EventThreadTimer] = [:]
    private var wheelAction: [Int32: SMAction] = [:]
    // Remaining accelerated line deltas from a successful physical Launchpad gesture.
    // The first ordinary tick supplies 0.04 progress; these add 1.60 over 90 ms.
    private static let launchpadCompletionDeltas: [Double] = [1, 5, 7, 8, 9, 10]
    private struct LaunchpadCompletion { var sign: Double; var physicalDirection: Int; var frame = 0 }
    private var launchpadCompletions: [Int32: LaunchpadCompletion] = [:]
    private var launchpadCompletionTimers: [Int32: EventThreadTimer] = [:]
    private var launchpadReturnDevices: Set<Int32> = []
    private var zoomAnimations: [Int32: ZoomAnimation] = [:]
    private var wheelScrollers: [Int32: (SMAction.Kind, SmoothedScrollingTransformer)] = [:]
    private var zoomTimer: EventThreadTimer?
    private var dockOwner: Int32?
    private static let scripts = DispatchQueue(label: "local.sun.SunMouse.scripts")
    private static let scriptSlots = DispatchSemaphore(value: 4)

    init(
        eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduleTimer: @escaping TimerScheduler = { interval, repeats, handler in
            EventThread.shared.scheduleTimer(interval: interval, repeats: repeats, handler: handler)
        },
        dockGestureSink: @escaping DockGestureSink = { progress, velocity, motion, phase in
            SMPostDockGesture(progress, velocity, motion, phase)
        }
    ) {
        self.eventSink = eventSink
        self.now = now
        self.scheduleTimer = scheduleTimer
        self.dockGestureSink = dockGestureSink
    }
    func perform(_ action: SMAction, app: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.perform(action, app: app) }
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app else { return }
        switch action.kind {
        case .builtin:
            if let builtin = Scheme.Buttons.Mapping.Action.Arg0(rawValue: action.builtin) { executor.perform(.arg0(builtin), targetBundleIdentifier: app) }
        case .shortcut:
            // Do not refocus an application behind the user's back after a deferred click.
            DispatchQueue.main.async {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app else { return }
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: action.keyCode, keyDown: down)
                    e?.flags = CGEventFlags(rawValue: action.modifiers)
                    e?.setIntegerValueField(.eventSourceUserData, value: SMRuntime.marker)
                    e?.post(tap: .cgSessionEventTap)
                }
            }
        case .script:
            guard Self.scriptSlots.wait(timeout: .now()) == .success else { report("脚本队列已满，已忽略本次触发。"); return }
            Self.scripts.async {
                defer { Self.scriptSlots.signal() }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", action.script]
                let pipe = Pipe(); process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
                let lock = NSLock(); var errorData = Data()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let data = h.availableData
                    lock.lock(); if errorData.count < 65536 { errorData.append(data.prefix(65536 - errorData.count)) }; lock.unlock()
                }
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                do {
                    try process.run()
                    let timedOut = done.wait(timeout: .now() + 10) == .timedOut
                    if timedOut {
                        process.terminate()
                        if done.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 1) }
                    }
                    pipe.fileHandleForReading.readabilityHandler = nil
                    if timedOut { self.report("AppleScript 执行超过 10 秒，已停止。") }
                    else if process.terminationStatus != 0 {
                        lock.lock(); let data = errorData; lock.unlock()
                        self.report(String(data: data, encoding: .utf8) ?? "AppleScript 执行失败。")
                    }
                } catch { pipe.fileHandleForReading.readabilityHandler = nil; self.report(error.localizedDescription) }
            }
        default: break
        }
    }
    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: SMRuntime.marker)
        eventSink(e)
    }
    func continuous(_ action: SMAction, device: Int32, delta: CGPoint, phase: Int) {
        if action.kind == .dragScroll {
            if phase == 1 { motions[device] = Motion(action: action) }
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(delta.y), wheel2: Int32(-delta.x), wheel3: 0)
            scroll?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            post(scroll)
            GestureEvent(scrollSource: nil, phase: CGSGesturePhase(rawValue: UInt8(phase))!, deltaX: -delta.x, deltaY: delta.y)?.send(to: post)
            if phase >= 4 { motions.removeValue(forKey: device) }
            return
        }
        if phase == 1 {
            // Dock's continuous gesture is system-wide: only one physical device may own it at a time.
            guard dockOwner == nil || dockOwner == device else { return }
            dockOwner = device
            motions[device] = Motion(action: action, axis: abs(delta.x) >= abs(delta.y) ? 1 : 2)
        }
        guard var motion = motions[device], dockOwner == device else { return }
        let amount = (motion.axis == 1 ? delta.x : -delta.y) / 600
        if phase < 4 { motion.origin += amount; motion.last = amount }
        if !dockGestureSink(motion.origin, motion.last * 100, Int32(motion.axis), Int32(phase)) { report("当前系统无法发送连续桌面手势。") }
        if phase >= 4 { motions.removeValue(forKey: device); dockOwner = nil } else { motions[device] = motion }
    }
    func wheel(
        _ action: SMAction,
        input: SMInput,
        reverseDirection: Bool = false,
        reverseZoom: Bool = false,
        smoothedZoom: Scheme.Scrolling.Smoothed? = nil
    ) {
        let inputDelta = reverseDirection ? -input.dy : input.dy
        if action.kind == .wheelZoom, let smoothedZoom {
            if wheelAction[input.device] != nil { endWheel(device: input.device) }
            feedSmoothedZoom(
                device: input.device,
                delta: reverseZoom ? -inputDelta : inputDelta,
                app: input.app,
                configuration: smoothedZoom
            )
            return
        }
        finishSmoothedZoom(device: input.device)
        if [.wheelQuick, .wheelPrecise, .wheelHorizontal].contains(action.kind) {
            if wheelScrollers[input.device]?.0 != action.kind {
                wheelScrollers[input.device]?.1.deactivate()
                let config = SMScrollConfiguration().runtimeConfiguration
                wheelScrollers[input.device] = (action.kind, SmoothedScrollingTransformer(
                    smoothed: .init(vertical: config, horizontal: config),
                    now: now,
                    eventSink: { [weak self] in self?.post($0) },
                    scheduleTimer: scheduleTimer
                ))
            }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                      wheel1: action.kind == .wheelHorizontal ? 0 : Int32(inputDelta),
                                      wheel2: action.kind == .wheelHorizontal ? Int32(inputDelta) : 0, wheel3: 0) else { return }
            event.setIntegerValueField(.eventSourceUserData,
                                      value: action.kind == .wheelQuick ? SMRuntime.quickMarker : action.kind == .wheelPrecise ? SMRuntime.preciseMarker : 0)
            _ = wheelScrollers[input.device]?.1.transform(event, in: .init(device: nil))
            return
        }
        if let old = wheelAction[input.device], old.kind != action.kind { endWheel(device: input.device) }
        let physicalWheelSign = input.physicalWheelSign ?? (input.dy > 0 ? 1 : -1)
        let returningFromLaunchpad = action.kind == .wheelPinch && physicalWheelSign > 0 &&
            launchpadReturnDevices.contains(input.device)
        // Begin a return from the open Launchpad, not from the opening gesture's accumulated offset.
        if returningFromLaunchpad { endWheel(device: input.device) }
        let phase = wheelAction[input.device] == nil ? 1 : 2
        wheelAction[input.device] = action
        var delta = action.kind == .wheelZoom && reverseZoom ? -inputDelta : inputDelta
        if action.kind == .wheelPinch, physicalWheelSign < 0 || returningFromLaunchpad { delta *= 1.6 }
        if action.kind != .wheelPinch ||
            (launchpadCompletions[input.device].map { $0.physicalDirection != physicalWheelSign } ?? false) {
            stopLaunchpadCompletion(device: input.device)
        }
        if action.kind == .wheelPinch {
            os_log("pinch input dy=%{public}.5f physical=%{public}d output=%{public}.5f phase=%{public}d",
                   log: Self.pinchLog, type: .debug, input.dy, physicalWheelSign, delta, phase)
        }
        sendWheelGesture(action, device: input.device, delta: delta, phase: phase, app: input.app)
        if action.kind == .wheelPinch, physicalWheelSign < 0 || returningFromLaunchpad, phase == 1, delta != 0,
           dockOwner == input.device {
            if returningFromLaunchpad { launchpadReturnDevices.remove(input.device) }
            else { launchpadReturnDevices.insert(input.device) }
            launchpadCompletions[input.device] = LaunchpadCompletion(sign: delta > 0 ? 1 : -1,
                                                                   physicalDirection: physicalWheelSign)
            launchpadCompletionTimers[input.device] = scheduleTimer(0.015, true) { [weak self] in
                self?.tickLaunchpadCompletion(device: input.device)
            }
        }
        wheelEnd[input.device]?.invalidate()
        wheelEnd[input.device] = scheduleTimer(0.15, false) { [weak self] in self?.endWheel(device: input.device) }
    }

    func tickLaunchpadCompletion(device: Int32) {
        guard var completion = launchpadCompletions[device], dockOwner == device,
              let action = wheelAction[device], action.kind == .wheelPinch else { return }
        let delta = Self.launchpadCompletionDeltas[completion.frame] * completion.sign * 1.6
        sendWheelGesture(action, device: device, delta: delta, phase: 2)
        // Use the same idle gap after the final update as an ordinary physical wheel gesture.
        wheelEnd[device]?.invalidate()
        wheelEnd[device] = scheduleTimer(0.15, false) { [weak self] in self?.endWheel(device: device) }
        completion.frame += 1
        if completion.frame == Self.launchpadCompletionDeltas.count {
            stopLaunchpadCompletion(device: device)
        } else {
            launchpadCompletions[device] = completion
        }
    }

    private func stopLaunchpadCompletion(device: Int32) {
        launchpadCompletionTimers.removeValue(forKey: device)?.invalidate()
        launchpadCompletions.removeValue(forKey: device)
    }

    func clearLaunchpadReturn() {
        launchpadReturnDevices.removeAll()
    }

    private func feedSmoothedZoom(
        device: Int32,
        delta: Double,
        app: String,
        configuration: Scheme.Scrolling.Smoothed
    ) {
        if zoomAnimations[device]?.configuration != configuration {
            finishSmoothedZoom(device: device)
            zoomAnimations[device] = ZoomAnimation(
                configuration: configuration,
                engine: SmoothedScrollingEngine(smoothed: .init(vertical: configuration, horizontal: nil)),
                app: app
            )
        }
        guard var animation = zoomAnimations[device] else { return }
        let wasRunning = animation.engine.isRunning
        animation.app = app
        animation.engine.feed(deltaX: 0, deltaY: delta * 36, timestamp: now(), mode: .zoom)
        if wasRunning, !animation.engine.isRunning {
            if animation.hasBegun { postZoom(magnification: 0, phase: .ended, app: animation.app) }
            zoomAnimations.removeValue(forKey: device)
            stopZoomTimerIfIdle()
            return
        }
        zoomAnimations[device] = animation
        startZoomTimerIfNeeded()
    }

    private func startZoomTimerIfNeeded() {
        guard zoomTimer == nil else { return }
        zoomTimer = scheduleTimer(1.0 / 120.0, true) { [weak self] in
            self?.tickZoomAnimations()
        }
    }

    func tickZoomAnimations() {
        let timestamp = now()
        for device in Array(zoomAnimations.keys) {
            guard var animation = zoomAnimations[device] else { continue }
            guard let emission = animation.engine.advance(to: timestamp) else {
                zoomAnimations[device] = animation
                continue
            }
            switch emission.phase {
            case .touchBegan:
                postZoom(magnification: emission.deltaY / 800, phase: .began, app: animation.app)
                animation.hasBegun = true
            case .touchChanged, .momentumBegan, .momentumChanged:
                let phase: CGSGesturePhase = animation.hasBegun ? .changed : .began
                postZoom(magnification: emission.deltaY / 800, phase: phase, app: animation.app)
                animation.hasBegun = true
            case .touchEnded:
                break
            case .momentumEnded:
                if animation.hasBegun { postZoom(magnification: 0, phase: .ended, app: animation.app) }
                zoomAnimations.removeValue(forKey: device)
                continue
            }
            zoomAnimations[device] = animation
        }
        stopZoomTimerIfIdle()
    }

    private func finishSmoothedZoom(device: Int32) {
        guard let animation = zoomAnimations.removeValue(forKey: device) else { return }
        if animation.hasBegun { postZoom(magnification: 0, phase: .ended, app: animation.app) }
        stopZoomTimerIfIdle()
    }

    private func stopZoomTimerIfIdle() {
        guard zoomAnimations.isEmpty else { return }
        zoomTimer?.invalidate()
        zoomTimer = nil
    }

    private func sendWheelGesture(
        _ action: SMAction,
        device: Int32,
        delta: Double,
        phase: Int,
        app: String = ""
    ) {
        if action.kind == .wheelSpaces || action.kind == .wheelPinch {
            if phase == 1 {
                guard dockOwner == nil || dockOwner == device else { return }
                dockOwner = device; motions[device] = Motion(action: action, axis: action.kind == .wheelSpaces ? 1 : 3)
            }
            guard var m = motions[device], dockOwner == device else { return }
            m.origin += delta * 0.025; if delta != 0 { m.last = delta * 0.025 }
            if action.kind == .wheelPinch {
                os_log("pinch dock progress=%{public}.5f velocity=%{public}.5f phase=%{public}d",
                       log: Self.pinchLog, type: .debug, m.origin, m.last * 100, phase)
            }
            if !dockGestureSink(m.origin, m.last * 100, Int32(m.axis), Int32(phase)) { report("当前系统无法发送连续桌面手势。") }
            if phase >= 4 { motions.removeValue(forKey: device); dockOwner = nil } else { motions[device] = m }
        } else {
            if action.kind == .wheelZoom {
                let gesturePhase = CGSGesturePhase(rawValue: UInt8(phase))!
                postZoom(magnification: delta * 36.0 / 800.0, phase: gesturePhase, app: app)
            } else {
                let e = CGEvent(source: nil); e?.type = CGEventType(rawValue: 29)!
                e?.setIntegerValueField(CGEventField(rawValue: 110)!, value: 5)
                e?.setIntegerValueField(CGEventField(rawValue: 132)!, value: Int64(phase))
                e?.setDoubleValueField(CGEventField(rawValue: 114)!, value: delta * 3)
                post(e)
            }
        }
    }
    func endWheel(device: Int32) {
        stopLaunchpadCompletion(device: device)
        guard let action = wheelAction.removeValue(forKey: device) else { return }
        sendWheelGesture(action, device: device, delta: 0, phase: 4)
        wheelEnd.removeValue(forKey: device)?.invalidate()
    }

    private func postZoom(magnification: Double, phase: CGSGesturePhase, app: String) {
        var magnification = magnification
        if phase == .began, Self.chromiumBundleIdentifiers.contains(where: app.contains) {
            // Chromium ignores the first delta and needs a larger first changed
            // value, matching Mac Mouse Fix's compatibility path.
            GestureEvent(zoomSource: nil, phase: .began, magnification: magnification)?.send(to: post)
            magnification += magnification > 0 ? 380.0 / 800.0 : -250.0 / 800.0
            GestureEvent(zoomSource: nil, phase: .changed, magnification: magnification)?.send(to: post)
            return
        }
        GestureEvent(zoomSource: nil, phase: phase, magnification: magnification)?.send(to: post)
    }

    private static let chromiumBundleIdentifiers = [
        "com.google.Chrome",
        "org.chromium.Chromium",
        "company.thebrowser.Browser",
        "com.operasoftware.Opera",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.brave.Browser"
    ]
    func tickWheelScrolling() {
        for (_, scroller) in wheelScrollers.values { scroller.tick() }
    }

    func cancel(device: Int32) {
        wheelScrollers.removeValue(forKey: device)?.1.deactivate()
        launchpadReturnDevices.remove(device)
        endWheel(device: device)
        finishSmoothedZoom(device: device)
        if let motion = motions[device] {
            continuous(motion.action, device: device, delta: .zero, phase: 8)
        }
    }

    func cancelAll() {
        for (_, scroller) in wheelScrollers.values { scroller.deactivate() }
        wheelScrollers.removeAll()
        clearLaunchpadReturn()
        for device in Array(wheelAction.keys) { endWheel(device: device) }
        for device in Array(zoomAnimations.keys) { finishSmoothedZoom(device: device) }
        for (device, motion) in Array(motions) { continuous(motion.action, device: device, delta: .zero, phase: 8) }
    }
    private func report(_ message: String) { DispatchQueue.main.async { SMRuleStore.shared.lastError = message } }
}
