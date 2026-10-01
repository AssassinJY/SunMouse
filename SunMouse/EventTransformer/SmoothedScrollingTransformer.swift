// Scroll animation behavior derived from Mac Mouse Fix.
// Copyright (c) 2019-2026 Noah Nuebling
// Licensed under the MMF License. See Licenses/MMF-License.txt.

import Foundation
import GestureKit
import os.log

final class SmoothedScrollingTransformer: EventTransformer, Deactivatable {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier!, category: "SmoothedScrolling"
    )
    private static var instances: [WeakRef<SmoothedScrollingTransformer>] = []
    private var lastDeviceID: Int32?
    static func interrupt(device: Int32) {
        instances.removeAll { $0.value == nil }
        for ref in instances where ref.value?.lastDeviceID == device { ref.value?.deactivate() }
    }
    private static let timerInterval: TimeInterval = 1.0 / 120.0
    private let smoothed: Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Smoothed>
    private let highResolutionWheelMultiplier: (EventTransformerContext) -> Int?
    private var mmfLineRemainders = [0.0, 0.0]
    private var mmfLineSigns: [FloatingPointSign?] = [nil, nil]
    private var phaseSimulation: Bool?
    private let scheduleTimer: (TimeInterval, Bool, @escaping () -> Void) -> EventThreadTimer?
    private let now: () -> TimeInterval
    private let eventSink: (CGEvent) -> Void
    private let delivery = SmoothedScrollEventDelivery()

    private var engine: SmoothedScrollingEngine
    private var timer: EventThreadTimer?
    private var lastFlags: CGEventFlags = []
    private var syntheticGestureScrollSeriesActive = false
    private var syntheticMomentumScrollActive = false

    init(
        smoothed: Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Smoothed>,
        highResolutionWheelMultiplier: @escaping (EventTransformerContext) -> Int? = {
            $0.device?.highResolutionWheelNormalizationMultiplier
        },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        scheduleTimer: @escaping (TimeInterval, Bool, @escaping () -> Void) -> EventThreadTimer? = {
            EventThread.shared.scheduleTimer(interval: $0, repeats: $1, handler: $2)
        }
    ) {
        self.smoothed = smoothed
        self.highResolutionWheelMultiplier = highResolutionWheelMultiplier
        self.now = now
        self.eventSink = eventSink
        self.scheduleTimer = scheduleTimer
        engine = SmoothedScrollingEngine(smoothed: smoothed)
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakRef(self))
    }

    func transform(_ event: CGEvent, in context: EventTransformerContext) -> CGEvent? {
        guard event.type == .scrollWheel else {
            return event
        }

        lastDeviceID = context.device?.id

        let view = ScrollWheelEventView(event)

        if event.isSunMouseSyntheticEvent {
            return event
        }

        let marker = event.getIntegerValueField(.eventSourceUserData)
        let mode: MMFScrollDynamics.Mode = marker == SMRuntime.preciseMarker ? .precise : marker == SMRuntime.quickMarker ? .quick : .normal
        let mmf = smoothed.vertical?.mmf ?? smoothed.horizontal?.mmf
        if mmf?.smoothness == .off, mmf?.speed == .system, mode == .normal { return event }
        // MMF reads point deltas for system speed; custom speed uses only the
        // axis and sign (one physical tick), not the accelerated line magnitude.
        let deltaX = mmf != nil ? (view.deltaXPt != 0 ? view.deltaXPt : deltaXInPixels(from: view, in: context)) : deltaXInPixels(from: view, in: context)
        let deltaY = mmf != nil ? (view.deltaYPt != 0 ? view.deltaYPt : deltaYInPixels(from: view, in: context)) : deltaYInPixels(from: view, in: context)
        let hasNativePhase = view.scrollPhase != nil
        let hasNativeMomentum = view.momentumPhase != .none

        // Mac Mouse Fix only intercepts discrete, axis-aligned wheel events.
        // Preserve trackpad and other native continuous gesture streams.
        if view.continuous || hasNativePhase || hasNativeMomentum || deltaX != 0 && deltaY != 0 {
            return event
        }

        let smoothsX = smoothed.horizontal != nil
        let smoothsY = smoothed.vertical != nil
        let handlesX = smoothsX && deltaX != 0
        let handlesY = smoothsY && deltaY != 0
        let interceptsX = smoothsX && deltaX != 0
        let interceptsY = smoothsY && deltaY != 0

        guard interceptsX || interceptsY else {
            return event
        }

        if handlesX || handlesY {
            lastFlags = event.flags
            if let mmf {
                phaseSimulation = mmf.smoothness != .off && (mode == .quick || mode == .normal && mmf.sendsPhases)
            }
            if handlesX != handlesY {
                engine.resetOtherAxis(ifExclusiveIncomingAxis: handlesX ? .horizontal : .vertical)
            }
            let wasRunning = engine.isRunning
            if !wasRunning { resetMMFLines() }
            engine.feed(
                deltaX: handlesX ? deltaX : 0,
                deltaY: handlesY ? deltaY : 0,
                timestamp: now(),
                inputKind: .wheel,
                mode: mode,
                screenSize: Self.displayHeight(at: event.location)
            )
            if wasRunning, !engine.isRunning, mmf != nil {
                deactivate()
            }
            if mmf?.smoothness == .off {
                // Acceleration remains active with smoothing off, with no timer delay.
                tick(); tick(); tick()
            } else {
                startTimerIfNeeded()
            }
        }

        let passthroughEvent = event.copy() ?? event
        let passthroughView = ScrollWheelEventView(passthroughEvent)
        if interceptsX {
            delivery.zeroHorizontal(on: passthroughView)
        }
        if interceptsY {
            delivery.zeroVertical(on: passthroughView)
        }

        return delivery.deltaXInPixels(from: passthroughView) == 0
            && delivery.deltaYInPixels(from: passthroughView) == 0
            ? nil
            : passthroughEvent
    }

    private static func displayHeight(at point: CGPoint) -> Double {
        var display: CGDirectDisplayID = CGMainDisplayID()
        var count: UInt32 = 0
        _ = CGGetDisplaysWithPoint(point, 1, &display, &count)
        return CGDisplayBounds(display).height
    }

    func deactivate() {
        if syntheticMomentumScrollActive {
            post(emission: .init(deltaX: 0, deltaY: 0, phase: .momentumEnded))
        }
        endSyntheticGestureScrollSeriesIfNeeded(phase: .cancelled)
        stopTimer()
        engine = SmoothedScrollingEngine(smoothed: smoothed)
        delivery.resetPointDeltaRemainders()
        resetMMFLines()
        lastFlags = []
        syntheticMomentumScrollActive = false
    }

    private func startTimerIfNeeded() {
        guard timer == nil else {
            return
        }

        timer = scheduleTimer(Self.timerInterval, true) { [weak self] in
            self?.tick()
        }
    }

    private func deltaXInPixels(from view: ScrollWheelEventView, in context: EventTransformerContext) -> Double {
        guard let multiplier = highResolutionWheelMultiplier(context),
              multiplier > 1,
              !view.continuous else {
            return delivery.deltaXInPixels(from: view)
        }

        let unitResolution = LogitechHighResolutionWheelUnitReader.horizontalUnitResolution(
            from: view,
            multiplier: multiplier
        )
        let smoothedUnits = Self.smoothedHighResolutionUnits(from: unitResolution)
        return smoothedUnits
            * SmoothedScrollEventDelivery.inputLineStepInPoints
            / Double(multiplier)
    }

    private func deltaYInPixels(from view: ScrollWheelEventView, in context: EventTransformerContext) -> Double {
        guard let multiplier = highResolutionWheelMultiplier(context),
              multiplier > 1,
              !view.continuous else {
            return delivery.deltaYInPixels(from: view)
        }

        let unitResolution = LogitechHighResolutionWheelUnitReader.verticalUnitResolution(
            from: view,
            multiplier: multiplier
        )
        let smoothedUnits = Self.smoothedHighResolutionUnits(from: unitResolution)
        return smoothedUnits
            * SmoothedScrollEventDelivery.inputLineStepInPoints
            / Double(multiplier)
    }

    static func smoothedHighResolutionUnits(
        from unitResolution: LogitechHighResolutionWheelUnitReader.UnitResolution
    ) -> Double {
        let rawMagnitude = abs(unitResolution.rawUnits)
        guard rawMagnitude > 1 else {
            return unitResolution.rawUnits
        }

        let acceleratedMagnitude = abs(unitResolution.units)
        let accelerationConfidence = 1 - 1 / rawMagnitude
        let magnitude = rawMagnitude + (acceleratedMagnitude - rawMagnitude) * accelerationConfidence
        return unitResolution.rawUnits.sign == .minus ? -magnitude : magnitude
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard let emission = engine.advance(to: now()) else {
            if !engine.isRunning {
                stopTimer()
                delivery.resetPointDeltaRemainders()
            }
            return
        }

        post(emission: emission)

        if !engine.isRunning {
            stopTimer()
            delivery.resetPointDeltaRemainders()
        }
    }

    private func post(emission: SmoothedScrollingEngine.Emission) {
        let mmf = smoothed.vertical?.mmf ?? smoothed.horizontal?.mmf
        guard
            let event = mmf != nil ? CGEvent(source: nil) : CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: 0,
                wheel3: 0
            )
        else {
            return
        }

        event.type = .scrollWheel
        let view = ScrollWheelEventView(event)
        view.continuous = true
        if emission.phase == .touchBegan, syntheticMomentumScrollActive {
            post(emission: .init(deltaX: 0, deltaY: 0, phase: .momentumEnded))
        }
        let accumulatesSubpixelDelta = true
        delivery.setSyntheticHorizontal(
            emission.deltaX,
            on: view,
            accumulatesSubpixelDelta: accumulatesSubpixelDelta
        )
        delivery.setSyntheticVertical(
            emission.deltaY,
            on: view,
            accumulatesSubpixelDelta: accumulatesSubpixelDelta
        )

        guard let phase = syntheticPhase(for: emission.phase, hasDelta: delivery.hasDelta(on: view)) else {
            return
        }

        let pointX = view.deltaXPt
        let pointY = view.deltaYPt
        if let mmf {
            let off = mmf.smoothness == .off
            view.continuous = !off
            let lineX = mmfLine(pointX, axis: 0, animated: !off)
            let lineY = mmfLine(pointY, axis: 1, animated: !off)
            view.deltaX = mmfIntegerLine(lineX)
            view.deltaY = mmfIntegerLine(lineY)
            // Setting CGEvent's line fields can recompute point deltas. Write
            // the independent representations in MMF's order using raw fixed16.
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(pointX))
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pointY))
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Int64(lineX * 65536))
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Int64(lineY * 65536))
            event.setIntegerValueField(CGEventField(rawValue: 137)!, value: 1)
        }
        let phases = delivery.phasesFor(phase, appliesPhases: allowsBouncingForConfiguredAxes())
        delivery.apply(phases: phases, to: view)
        guard view.scrollPhase != nil || view.momentumPhase != .none || delivery.hasDelta(on: view)
        else {
            return
        }
        event.isSunMouseSyntheticEvent = true
        event.flags = lastFlags
        let postedDeltaX = view.deltaXFixedPt
        let postedDeltaY = view.deltaYFixedPt
        postGestureScrollCompanionsIfNeeded(
            scrollPhase: phases.scrollPhase,
            deltaX: mmf != nil ? pointX * 1.67 : postedDeltaX,
            deltaY: mmf != nil ? pointY * 1.67 : postedDeltaY
        )
        eventSink(event)
        updateSyntheticMomentumState(afterPosting: phase)

        os_log(
            "post smoothed scroll deltaX=%{public}.3f deltaY=%{public}.3f phase=%{public}@ momentum=%{public}@",
            log: Self.log,
            type: .info,
            postedDeltaX,
            postedDeltaY,
            String(describing: view.scrollPhase),
            String(describing: view.momentumPhase)
        )
    }

    private func resetMMFLines() {
        mmfLineRemainders = [0, 0]
        mmfLineSigns = [nil, nil]
    }

    private func mmfLine(_ points: Double, axis: Int, animated: Bool) -> Double {
        let lines = points / 10
        guard animated, points != 0 else { return lines }
        if mmfLineSigns[axis] == nil { mmfLineSigns[axis] = points.sign }
        let precise = lines + mmfLineRemainders[axis]
        let rounded = precise.rounded()
        let stable = abs(precise - rounded) < 1e-9 ? rounded : precise
        let output = mmfLineSigns[axis] == .minus ? floor(stable) : ceil(stable)
        mmfLineRemainders[axis] = precise - output
        return output
    }

    private func mmfIntegerLine(_ value: Double) -> Int64 {
        let truncated = Int64(value.rounded(.towardZero))
        return truncated == 0 && value != 0 ? (value < 0 ? -1 : 1) : truncated
    }

    private func syntheticPhase(
        for phase: SmoothedScrollingEngine.Phase,
        hasDelta: Bool
    ) -> SmoothedScrollingEngine.Phase? {
        switch phase {
        case .touchBegan:
            return hasDelta ? (syntheticGestureScrollSeriesActive ? .touchChanged : .touchBegan) : nil
        case .touchChanged:
            guard hasDelta else {
                return nil
            }
            return syntheticGestureScrollSeriesActive ? .touchChanged : .touchBegan
        case .touchEnded:
            return syntheticGestureScrollSeriesActive ? .touchEnded : nil
        case .momentumBegan:
            return hasDelta ? .momentumBegan : nil
        case .momentumChanged:
            guard hasDelta else {
                return nil
            }
            return syntheticMomentumScrollActive ? .momentumChanged : .momentumBegan
        case .momentumEnded:
            return syntheticMomentumScrollActive ? .momentumEnded : nil
        }
    }

    private func updateSyntheticMomentumState(afterPosting phase: SmoothedScrollingEngine.Phase) {
        switch phase {
        case .momentumBegan:
            syntheticMomentumScrollActive = true
        case .momentumEnded:
            syntheticMomentumScrollActive = false
        case .touchBegan, .touchChanged, .touchEnded, .momentumChanged:
            break
        }
    }

    private func postGestureScrollCompanionsIfNeeded(
        scrollPhase: CGScrollPhase?,
        deltaX: Double,
        deltaY: Double
    ) {
        guard let scrollPhase, let gesturePhase = CGSGesturePhase(scrollPhase: scrollPhase) else {
            return
        }

        if scrollPhase == .began, !syntheticGestureScrollSeriesActive {
            GestureEvent(
                scrollSource: nil,
                phase: .mayBegin,
                deltaX: 0,
                deltaY: 0,
                flags: lastFlags
            )?.send(to: eventSink)
            GestureEvent(
                scrollSeriesSource: nil,
                started: true,
                flags: lastFlags
            )?.send(to: eventSink)
            syntheticGestureScrollSeriesActive = true
        }

        GestureEvent(
            scrollSource: nil,
            phase: gesturePhase,
            deltaX: deltaX,
            deltaY: deltaY,
            flags: lastFlags
        )?.send(to: eventSink)

        if scrollPhase == .ended || scrollPhase == .cancelled {
            GestureEvent(
                scrollSeriesSource: nil,
                started: false,
                flags: lastFlags
            )?.send(to: eventSink)
            syntheticGestureScrollSeriesActive = false
        }
    }

    private func endSyntheticGestureScrollSeriesIfNeeded(phase: CGSGesturePhase) {
        guard syntheticGestureScrollSeriesActive else {
            return
        }

        GestureEvent(
            scrollSource: nil,
            phase: phase,
            deltaX: 0,
            deltaY: 0,
            flags: lastFlags
        )?.send(to: eventSink)
        GestureEvent(
            scrollSeriesSource: nil,
            started: false,
            flags: lastFlags
        )?.send(to: eventSink)
        syntheticGestureScrollSeriesActive = false
    }

    private func allowsBouncingForConfiguredAxes(
        interceptsX: Bool = true,
        interceptsY: Bool = true
    ) -> Bool {
        if let phaseSimulation { return phaseSimulation }
        if interceptsX, smoothed.horizontal?.allowsBouncing == false {
            return false
        }
        if interceptsY, smoothed.vertical?.allowsBouncing == false {
            return false
        }
        return true
    }
}

private extension CGSGesturePhase {
    init?(scrollPhase: CGScrollPhase) {
        guard let rawValue = UInt8(exactly: scrollPhase.rawValue) else {
            return nil
        }
        self.init(rawValue: rawValue)
    }
}

private final class SmoothedScrollEventDelivery {
    static let inputLineStepInPoints = 36.0
    private static let outputLineStepInPoints = 12.0
    private var pointDeltaAccumulator = SmoothedScrollPointDeltaAccumulator()

    func resetPointDeltaRemainders() {
        pointDeltaAccumulator.reset()
    }

    func apply(
        phases: (scrollPhase: CGScrollPhase?, momentumPhase: CGMomentumScrollPhase),
        to view: ScrollWheelEventView
    ) {
        view.scrollPhase = phases.scrollPhase
        view.momentumPhase = phases.momentumPhase
    }

    func phasesFor(
        _ phase: SmoothedScrollingEngine.Phase,
        appliesPhases: Bool = true
    ) -> (scrollPhase: CGScrollPhase?, momentumPhase: CGMomentumScrollPhase) {
        guard appliesPhases else {
            return (nil, .none)
        }

        switch phase {
        case .touchBegan:
            return (.began, .none)
        case .touchChanged:
            return (.changed, .none)
        case .touchEnded:
            return (.ended, .none)
        case .momentumBegan:
            return (nil, .begin)
        case .momentumChanged:
            return (nil, .continuous)
        case .momentumEnded:
            return (nil, .end)
        }
    }

    func deltaXInPixels(from view: ScrollWheelEventView) -> Double {
        if !view.continuous {
            if view.deltaX != 0 {
                return Double(view.deltaX) * Self.inputLineStepInPoints
            }
            if view.deltaXPt != 0 {
                return view.deltaXPt * Self.inputLineStepInPoints
            }
            if view.deltaXFixedPt != 0 {
                return view.deltaXFixedPt * Self.inputLineStepInPoints * 10
            }
        }
        if view.deltaXFixedPt != 0 {
            return view.deltaXFixedPt
        }
        if view.deltaXPt != 0 {
            return view.deltaXPt
        }
        return Double(view.deltaX) * Self.inputLineStepInPoints
    }

    func deltaYInPixels(from view: ScrollWheelEventView) -> Double {
        if !view.continuous {
            if view.deltaY != 0 {
                return Double(view.deltaY) * Self.inputLineStepInPoints
            }
            if view.deltaYPt != 0 {
                return view.deltaYPt * Self.inputLineStepInPoints
            }
            if view.deltaYFixedPt != 0 {
                return view.deltaYFixedPt * Self.inputLineStepInPoints * 10
            }
        }
        if view.deltaYFixedPt != 0 {
            return view.deltaYFixedPt
        }
        if view.deltaYPt != 0 {
            return view.deltaYPt
        }
        return Double(view.deltaY) * Self.inputLineStepInPoints
    }

    func setHorizontal(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaX = integerDelta(for: value)
        view.deltaXPt = pointDeltaAccumulator.horizontalPointDelta(for: value)
        view.deltaXFixedPt = value
        view.ioHidScrollX = value
    }

    func setVertical(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaY = integerDelta(for: value)
        view.deltaYPt = pointDeltaAccumulator.verticalPointDelta(for: value)
        view.deltaYFixedPt = value
        view.ioHidScrollY = value
    }

    func setSyntheticHorizontal(
        _ value: Double,
        on view: ScrollWheelEventView,
        accumulatesSubpixelDelta: Bool
    ) {
        setSyntheticHorizontalOutput(
            pointDeltaAccumulator.horizontalPointDelta(
                for: value,
                accumulates: accumulatesSubpixelDelta
            ),
            on: view
        )
    }

    func setSyntheticVertical(
        _ value: Double,
        on view: ScrollWheelEventView,
        accumulatesSubpixelDelta: Bool
    ) {
        setSyntheticVerticalOutput(
            pointDeltaAccumulator.verticalPointDelta(
                for: value,
                accumulates: accumulatesSubpixelDelta
            ),
            on: view
        )
    }

    func zeroHorizontal(on view: ScrollWheelEventView) {
        view.deltaX = 0
        view.deltaXPt = 0
        view.deltaXFixedPt = 0
        view.ioHidScrollX = 0
    }

    func zeroVertical(on view: ScrollWheelEventView) {
        view.deltaY = 0
        view.deltaYPt = 0
        view.deltaYFixedPt = 0
        view.ioHidScrollY = 0
    }

    func hasDelta(on view: ScrollWheelEventView) -> Bool {
        view.deltaX != 0 || view.deltaY != 0 ||
            view.deltaXPt != 0 || view.deltaYPt != 0 ||
            view.deltaXFixedPt != 0 || view.deltaYFixedPt != 0 ||
            view.ioHidScrollX != 0 || view.ioHidScrollY != 0
    }

    private func setSyntheticHorizontalOutput(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaX = integerDelta(for: value)
        view.deltaXPt = value
        view.deltaXFixedPt = value
        view.ioHidScrollX = value
    }

    private func setSyntheticVerticalOutput(_ value: Double, on view: ScrollWheelEventView) {
        view.deltaY = integerDelta(for: value)
        view.deltaYPt = value
        view.deltaYFixedPt = value
        view.ioHidScrollY = value
    }

    private func integerDelta(for value: Double) -> Int64 {
        Int64((value / Self.outputLineStepInPoints).rounded(.towardZero))
    }
}

struct SmoothedScrollPointDeltaAccumulator {
    private var horizontalRemainder = 0.0
    private var verticalRemainder = 0.0

    mutating func reset() {
        horizontalRemainder = 0
        verticalRemainder = 0
    }

    mutating func horizontalPointDelta(for value: Double, accumulates: Bool = true) -> Double {
        pointDelta(for: value, remainder: &horizontalRemainder, accumulates: accumulates)
    }

    mutating func verticalPointDelta(for value: Double, accumulates: Bool = true) -> Double {
        pointDelta(for: value, remainder: &verticalRemainder, accumulates: accumulates)
    }

    private func pointDelta(for value: Double, remainder: inout Double, accumulates: Bool) -> Double {
        guard accumulates else {
            remainder = 0
            return truncatedPointDelta(for: value)
        }

        let combinedValue = value + remainder
        let pointDelta = truncatedPointDelta(for: combinedValue)
        remainder = combinedValue - pointDelta

        return pointDelta
    }

    private func truncatedPointDelta(for value: Double) -> Double {
        let integral = value.rounded()
        let stable = abs(value - integral) < 1e-9 ? integral : value
        return Double(Int64(stable.rounded(.towardZero)))
    }
}
