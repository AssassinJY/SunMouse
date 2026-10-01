// Derived from Mac Mouse Fix's scroll animator design.
// Copyright (c) 2019-2026 Noah Nuebling
// Licensed under the MMF License. See Licenses/MMF-License.txt.

import Foundation

/// Animates discrete wheel ticks as finite-distance curves.
///
/// Each new tick is combined with the unfinished distance of the current
/// animation and restarts the curve from the current position. This mirrors
/// Mac Mouse Fix's TouchAnimator-based scrolling model; it deliberately does
/// not use a target-velocity filter or an exponential momentum tail.
final class SmoothedScrollingEngine {
    enum Phase { case touchBegan, touchChanged, touchEnded, momentumBegan, momentumChanged, momentumEnded }
    enum Axis { case horizontal, vertical }
    enum InputKind { case wheel, continuousGesture }

    struct Emission {
        var deltaX: Double
        var deltaY: Double
        var phase: Phase
    }

    private enum SessionState: Equatable { case idle, gesture, momentum }

    private struct AxisAnimator {
        let configuration: Scheme.Scrolling.Smoothed?
        var mmf: MMFScrollDynamics?
        var curve: MMFScrollCurve?
        var elapsed = 0.0
        init(configuration: Scheme.Scrolling.Smoothed?) {
            self.configuration = configuration
            mmf = configuration?.mmf.map { MMFScrollDynamics(configuration: $0) }
        }
        private(set) var distance = 0.0
        private(set) var progress = 0.0
        private(set) var duration: TimeInterval = 0.2
        private(set) var lastInputTimestamp: TimeInterval?

        var isEnabled: Bool { configuration != nil }
        var isRunning: Bool { isEnabled && abs(distance) > 0.001 && progress < 1 }
        var direction: FloatingPointSign? { isRunning ? distance.sign : nil }
        var remainingDistance: Double {
            if let curve { return distance.sign == .minus ? -(curve.distance - curve.value(at: elapsed)) : curve.distance - curve.value(at: elapsed) }
            return distance * (1 - eased(progress))
        }
        var inMomentum: Bool { curve.map { elapsed >= $0.transitionTime } ?? false }

        mutating func add(input: Double, timestamp: TimeInterval) -> Bool {
            guard let configuration, input != 0 else { return false }

            // Direction changes brake the active animation and consume the
            // first opposing tick, matching Mac Mouse Fix's control behavior.
            if let direction, direction != input.sign {
                reset()
                lastInputTimestamp = timestamp
                return true
            }

            if mmf != nil {
                let transformed = mmf!.distance(input: input, timestamp: timestamp)
                distance = (mmf!.startsSequence ? 0 : remainingDistance) + transformed
                curve = mmf!.curve(distance: distance)
                elapsed = 0
                progress = 0
                duration = curve!.duration
                lastInputTimestamp = timestamp
                return false
            }
            let interval = lastInputTimestamp.map { timestamp - $0 }
            let transformedInput = Self.distance(for: input, interval: interval, configuration: configuration)
            distance = remainingDistance + transformedInput
            progress = 0
            duration = Self.duration(configuration: configuration, interval: interval)
            lastInputTimestamp = timestamp
            return false
        }

        mutating func advance(by dt: TimeInterval) -> Double {
            guard isRunning else { return 0 }
            if let curve {
                let oldValue = curve.value(at: elapsed)
                elapsed += dt
                progress = duration > 0 ? min(elapsed / duration, 1) : 1
                let nextValue = duration == 0 ? curve.distance : curve.value(at: elapsed)
                let delta = (nextValue - oldValue) * (distance.sign == .minus ? -1 : 1)
                if progress >= 1 { distance = 0 }
                return delta
            }
            let oldProgress = progress
            progress = min(progress + dt / duration, 1)
            let delta = distance * (eased(progress) - eased(oldProgress))
            if progress >= 1 { distance = 0 }
            return delta
        }

        mutating func reset() {
            distance = 0
            progress = 0
        }

        private func eased(_ value: Double) -> Double {
            guard let preset = configuration?.resolvedPreset else { return value }
            let t = value.clamped(to: 0 ... 1)
            switch preset {
            case .linear: return t
            case .easeIn, .quadratic: return t * t
            case .cubic: return t * t * t
            case .quartic: return t * t * t * t
            case .easeOut: return 1 - pow(1 - t, 2)
            case .easeOutCubic: return 1 - pow(1 - t, 3)
            case .easeOutQuartic: return 1 - pow(1 - t, 4)
            case .easeInOut, .custom, .smooth: return t * t * (3 - 2 * t)
            case .easeInOutCubic:
                return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            case .easeInOutQuartic:
                return t < 0.5 ? 8 * pow(t, 4) : 1 - pow(-2 * t + 2, 4) / 2
            }
        }

        private static func distance(
            for input: Double,
            interval: TimeInterval?,
            configuration: Scheme.Scrolling.Smoothed
        ) -> Double {
            let speed = (configuration.speed?.asTruncatedDouble ?? 1)
                .clamped(to: Scheme.Scrolling.Smoothed.speedRange)
            let acceleration = (configuration.acceleration?.asTruncatedDouble ?? 1.2)
                .clamped(to: Scheme.Scrolling.Smoothed.accelerationRange)
            let speedFactor = 0.75 + speed * 0.35

            guard acceleration > 0, let interval, interval > 0 else { return input * speedFactor }

            // MMF derives per-tick distance from wheel tick frequency.
            let ticksPerSecond = 1 / interval.clamped(to: 1.0 / 120.0 ... 0.25)
            let rate = ((ticksPerSecond - 4) / 36).clamped(to: 0 ... 1)
            let accelerationFactor = 1 + acceleration * 0.22 * rate * rate
            return input * speedFactor * accelerationFactor
        }

        private static func duration(
            configuration: Scheme.Scrolling.Smoothed,
            interval: TimeInterval?
        ) -> TimeInterval {
            let response = (configuration.response?.asTruncatedDouble ?? 0.45)
                .clamped(to: Scheme.Scrolling.Smoothed.responseRange)
            let inertia = (configuration.inertia?.asTruncatedDouble ?? 0.65)
                .clamped(to: Scheme.Scrolling.Smoothed.inertiaRange)
            let slowDuration = 0.24 + inertia * 0.035
            let fastDuration = 0.075 + inertia * 0.012
            let ticksPerSecond = interval.map { 1 / $0.clamped(to: 1.0 / 120.0 ... 0.25) } ?? 4
            let rate = ((ticksPerSecond - 4) / 36).clamped(to: 0 ... 1)
            let responseBias = (response / 2).clamped(to: 0 ... 1)
            return (slowDuration + (fastDuration - slowDuration) * rate) * (1.1 - responseBias * 0.35)
        }
    }

    private var horizontal: AxisAnimator
    private var vertical: AxisAnimator
    private var state: SessionState = .idle
    private var lastTickTimestamp: TimeInterval?
    private var lastInputTimestamp: TimeInterval?
    private var gestureHasBegun = false
    private var pendingMomentumBegin = false
    private let inputGrace: TimeInterval = 1.0 / 25.0

    init(smoothed: Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Smoothed>) {
        horizontal = AxisAnimator(configuration: smoothed.horizontal)
        vertical = AxisAnimator(configuration: smoothed.vertical)
    }

    var isRunning: Bool { state != .idle || horizontal.isRunning || vertical.isRunning }

    var exclusiveActiveAxis: Axis? {
        switch (horizontal.isRunning, vertical.isRunning) {
        case (true, false): return .horizontal
        case (false, true): return .vertical
        default: return nil
        }
    }

    func resetOtherAxis(ifExclusiveIncomingAxis incomingAxis: Axis) {
        guard let active = exclusiveActiveAxis, active != incomingAxis else { return }
        switch active {
        case .horizontal: horizontal.reset()
        case .vertical: vertical.reset()
        }
    }

    func feed(
        deltaX: Double,
        deltaY: Double,
        timestamp: TimeInterval,
        inputKind: InputKind = .wheel,
        mode: MMFScrollDynamics.Mode = .normal,
        screenSize: Double = 1080
    ) {
        // Native continuous gestures are passed through by the transformer.
        guard inputKind == .wheel else { return }
        if !isRunning || horizontal.mmf != nil || vertical.mmf != nil { lastTickTimestamp = timestamp }
        horizontal.mmf?.mode = mode
        vertical.mmf?.mode = mode
        horizontal.mmf?.screenSize = screenSize * 1920 / 1080
        vertical.mmf?.screenSize = screenSize
        let cancelledX = horizontal.add(input: deltaX, timestamp: timestamp)
        let cancelledY = vertical.add(input: deltaY, timestamp: timestamp)
        lastInputTimestamp = timestamp

        if cancelledX || cancelledY {
            state = horizontal.isRunning || vertical.isRunning ? .gesture : .idle
            gestureHasBegun = false
            pendingMomentumBegin = false
            return
        }
        if deltaX != 0 || deltaY != 0 {
            state = .gesture
            if lastTickTimestamp == nil { lastTickTimestamp = timestamp }
        }
    }

    func advance(to timestamp: TimeInterval) -> Emission? {
        let previous = lastTickTimestamp ?? timestamp
        let hasMMF = horizontal.mmf != nil || vertical.mmf != nil
        let dt = hasMMF ? max(timestamp - previous, 0) : (timestamp - previous).clamped(to: 1.0 / 240.0 ... 1.0 / 24.0)
        lastTickTimestamp = timestamp
        let hasFreshInput = hasMMF
            ? (horizontal.isRunning && !horizontal.inMomentum || vertical.isRunning && !vertical.inMomentum)
            : (lastInputTimestamp.map { timestamp - $0 <= inputGrace } ?? false)

        // Phase boundaries carry no distance. Do not advance the finite curve
        // on this frame or that distance would be silently discarded.
        if state == .gesture, !hasFreshInput {
            gestureHasBegun = false
            if horizontal.isRunning || vertical.isRunning {
                state = .momentum
                pendingMomentumBegin = true
            } else {
                state = .idle
            }
            return .init(deltaX: 0, deltaY: 0, phase: .touchEnded)
        }

        let deltaX = horizontal.advance(by: dt)
        let deltaY = vertical.advance(by: dt)
        let hasMovement = abs(deltaX) >= 0.001 || abs(deltaY) >= 0.001
        let animationRunning = horizontal.isRunning || vertical.isRunning

        switch state {
        case .idle:
            return nil
        case .gesture:
            guard hasMovement else { return nil }
            let phase: Phase = gestureHasBegun ? .touchChanged : .touchBegan
            gestureHasBegun = true
            return .init(deltaX: deltaX, deltaY: deltaY, phase: phase)
        case .momentum:
            guard animationRunning || hasMovement else {
                state = .idle
                pendingMomentumBegin = false
                return .init(deltaX: 0, deltaY: 0, phase: .momentumEnded)
            }
            if pendingMomentumBegin {
                pendingMomentumBegin = false
                return .init(deltaX: deltaX, deltaY: deltaY, phase: .momentumBegan)
            }
            return .init(deltaX: deltaX, deltaY: deltaY, phase: .momentumChanged)
        }
    }
}

// Port of ScrollConfig, BezierCappedAccelerationCurve, LineHybridCurve and
// DragCurve at MMF 0c0fc99. Distances are points; time is seconds.
struct MMFScrollDynamics {
    enum Mode { case normal, precise, quick, zoom }
    let configuration: SMScrollConfiguration
    var mode: Mode = .normal
    var screenSize = 1080.0
    private var lastTime: TimeInterval?
    private var lastSign: FloatingPointSign?
    private var intervals: [Double] = []
    private var ticks = 0
    private var swipes = 0
    private var sequenceTicks = 0
    private var sequenceStart = 0.0
    private(set) var interval = 0.16
    private(set) var startsSequence = true

    init(configuration: SMScrollConfiguration, mode: Mode = .normal, screenSize: Double = 1080) {
        self.configuration = configuration
        self.mode = mode
        self.screenSize = screenSize
    }

    mutating func distance(input: Double, timestamp: Double) -> Double {
        let tickMax = mode == .quick ? 0.2 : 0.16
        let rawInterval = lastTime.map { max(timestamp - $0, 0.001) } ?? .infinity
        let directionChanged = lastSign != nil && lastSign != input.sign
        let first = directionChanged || rawInterval > tickMax
        sequenceTicks += 1
        if first {
            let swipeMax = mode == .quick ? 0.725 : configuration.smoothness == .high ? 0.6 : 0.375
            let minSpeed = mode == .quick || configuration.smoothness == .high ? 12.0 : 16.0
            if !directionChanged, ticks >= 2, rawInterval <= swipeMax,
               Double(sequenceTicks) / max(timestamp - sequenceStart, 0.001) >= minSpeed {
                swipes += 1
            } else {
                swipes = 0
                sequenceStart = timestamp
                sequenceTicks = 0
            }
            ticks = 0
            intervals = configuration.smoothness == .high && !configuration.precise ? [tickMax] : []
            interval = tickMax
        } else {
            ticks += 1
            intervals.append(rawInterval)
            intervals = Array(intervals.suffix(3))
            interval = intervals.reduce(0, +) / Double(intervals.count)
        }
        startsSequence = first && swipes == 0
        lastTime = timestamp
        lastSign = input.sign
        if configuration.speed == .system && mode == .normal { return input }

        let index = configuration.speed == .low ? 0 : configuration.speed == .high ? 2 : 1
        let minimum: Double
        var maximum: Double
        let curvature: Double
        if mode == .precise {
            minimum = 1; maximum = 20; curvature = 2
        } else if mode == .zoom {
            minimum = [45.0, 60, 90][index]
            maximum = [90.0, 120, 180][index]
            curvature = configuration.precise ? [0.75, 0.75, 0.25][index] : [0.25, 0, 0][index]
        } else if mode == .quick {
            minimum = screenSize * 0.85 * 0.5
            maximum = screenSize * 0.85 * 1.5
            curvature = 0
        } else {
            switch configuration.smoothness {
            case .off:
                minimum = configuration.precise ? 10 : [20.0, 30, 40][index]
                maximum = [40.0, 60, 80][index]
                curvature = [4.25, 3, 2.25][index]
            case .low, .regular:
                minimum = configuration.precise ? 10 : [30.0, 60, 120][index]
                maximum = [90.0, 120, 180][index]
                curvature = configuration.precise ? [0.75, 0.75, 0.25][index] : [0.25, 0, 0][index]
            case .high:
                minimum = configuration.precise ? 10 : [60.0, 90, 150][index]
                maximum = [120.0, 180, 240][index]
                curvature = configuration.precise ? [1.5, 1.25, 0.75][index] : 0
            }
            maximum *= 0.9 + 0.1 * screenSize / 1080
        }
        let rate = 1 / max(interval, 0.015)
        let x = ((rate - 1 / tickMax) / (1 / 0.015 - 1 / tickMax)).clamped(to: 0 ... 1)
        // MMF uses a Bezier of degree ceil(curvature + 1), with all
        // noninitial Y control points at the upper sensitivity.
        let degree = curvature + 1
        let points = (0 ... Int(ceil(degree))).map { i in
            CGPoint(x: min(Double(i) / degree, 1), y: i == 0 ? 0 : 1)
        }
        let sensitivity = minimum + (maximum - minimum) * Self.bezier(points, at: x)
        var speedup = 1.0
        if mode != .precise {
            let threshold = mode == .quick ? 1 : configuration.smoothness == .high ? 2 : configuration.smoothness == .off ? 6 : configuration.smoothness == .low ? 1 : 3
            let initial = mode == .quick ? 2.0 : configuration.smoothness == .off ? 1.4 : configuration.smoothness == .low ? 1 : 1.33
            let exponent = mode == .quick ? 10.0 : configuration.smoothness == .off ? 3 : 7.5
            let a = (initial - 1) / (pow(1.1, exponent) - 1)
            if swipes >= threshold {
                speedup = min(a * pow(1.1, Double(swipes - threshold) * exponent) + 1 - a, 100_000)
            }
        }
        // One callback is one tick regardless of macOS's accelerated line delta.
        return (input.sign == .minus ? -1 : 1) * floor(sensitivity) * speedup
    }

    func curve(distance: Double) -> MMFScrollCurve {
        if configuration.smoothness == .off { return .init(distance: distance, baseDuration: 0) }
        if mode == .zoom { return .init(distance: distance, baseDuration: 0.25, lowCurve: true, controlX: 0.5) }
        if mode == .precise { return .init(distance: distance, baseDuration: 0.14, coefficient: 15, exponent: 1.05, stopSpeed: 50) }
        if mode == .quick { return .init(distance: distance, baseDuration: 0.3, coefficient: 30, exponent: 0.7, stopSpeed: 1) }
        switch configuration.smoothness {
        case .off: return .init(distance: distance, baseDuration: 0)
        case .low:
            // MMF's low option is experimental and hidden in release UI.
            let x = ((0.16 - interval) / 0.159).clamped(to: 0 ... 1)
            return .init(distance: distance, baseDuration: 0.25 - 0.15 * x, lowCurve: true)
        case .regular:
            let x = ((0.16 - interval) / 0.159).clamped(to: 0 ... 1)
            let duration = 0.18 - 0.07 * (exp(4 * x) - 1) / (exp(4) - 1)
            return .init(distance: distance, baseDuration: duration, coefficient: 23, exponent: 1, stopSpeed: 30)
        case .high:
            return .init(distance: distance, baseDuration: 0.22, coefficient: 40, exponent: 0.7, stopSpeed: 30)
        }
    }

    static func bezier(_ points: [CGPoint], at x: Double) -> Double {
        if x <= 0 { return points.first!.y }
        if x >= 1 { return points.last!.y }
        func point(_ t: Double) -> CGPoint {
            var p = points
            for count in stride(from: p.count - 1, through: 1, by: -1) {
                for i in 0 ..< count {
                    p[i] = CGPoint(x: p[i].x * (1 - t) + p[i + 1].x * t,
                                   y: p[i].y * (1 - t) + p[i + 1].y * t)
                }
            }
            return p[0]
        }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 30 {
            let mid = (lo + hi) / 2
            if point(mid).x < x { lo = mid } else { hi = mid }
        }
        return point((lo + hi) / 2).y
    }
}

struct MMFScrollCurve {
    let distance: Double
    let baseDuration: Double
    private(set) var transitionTime: Double
    private let transitionDistance: Double
    private let coefficient: Double
    private let exponent: Double
    private let initialSpeed: Double
    private let dragDuration: Double
    private let lowCurve: Bool
    private let controlX: Double
    var duration: Double { transitionTime + dragDuration }

    init(distance: Double, baseDuration: Double, coefficient: Double = 0, exponent: Double = 1, stopSpeed: Double = 30, lowCurve: Bool = false, controlX: Double = 0.85) {
        self.distance = abs(distance)
        self.baseDuration = baseDuration
        self.coefficient = coefficient
        self.exponent = exponent
        self.lowCurve = lowCurve
        self.controlX = controlX
        let speed = abs(distance) / max(baseDuration, 0.0001)
        if coefficient == 0 || speed <= stopSpeed {
            transitionTime = baseDuration
            transitionDistance = abs(distance)
            initialSpeed = 0
            dragDuration = 0
        } else {
            func dragDistance(_ v: Double) -> Double {
                if exponent == 1 { return (v - stopSpeed) / coefficient }
                return (pow(v, 2 - exponent) - pow(stopSpeed, 2 - exponent)) / (coefficient * (2 - exponent))
            }
            if dragDistance(speed) > abs(distance) {
                transitionDistance = 0
                transitionTime = 0
                if exponent == 1 {
                    initialSpeed = abs(distance) * coefficient + stopSpeed
                } else {
                    initialSpeed = pow(abs(distance) * coefficient * (2 - exponent) + pow(stopSpeed, 2 - exponent), 1 / (2 - exponent))
                }
            } else {
                initialSpeed = speed
                transitionDistance = abs(distance) - dragDistance(speed)
                transitionTime = transitionDistance / speed
            }
            if exponent == 1 {
                dragDuration = log(initialSpeed / stopSpeed) / coefficient
            } else {
                dragDuration = (pow(initialSpeed, 1 - exponent) - pow(stopSpeed, 1 - exponent)) / (coefficient * (1 - exponent))
            }
        }
    }

    func value(at time: Double) -> Double {
        if time <= 0 { return 0 }
        if time >= duration { return distance }
        if time <= transitionTime {
            if lowCurve {
                return distance * MMFScrollDynamics.bezier([.zero, .zero, CGPoint(x: controlX, y: 1), CGPoint(x: 1, y: 1)], at: time / max(baseDuration, 0.0001))
            }
            return distance * time / max(baseDuration, 0.0001)
        }
        let t = time - transitionTime
        let dragDistance: Double
        if exponent == 1 {
            dragDistance = initialSpeed * (1 - exp(-coefficient * t)) / coefficient
        } else {
            let v = pow(max(pow(initialSpeed, 1 - exponent) - coefficient * (1 - exponent) * t, 0), 1 / (1 - exponent))
            dragDistance = (pow(initialSpeed, 2 - exponent) - pow(v, 2 - exponent)) / (coefficient * (2 - exponent))
        }
        return min(transitionDistance + dragDistance, distance)
    }
}
