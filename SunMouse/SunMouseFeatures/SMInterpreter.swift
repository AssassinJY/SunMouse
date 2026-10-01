import AppKit

struct SMInput {
    enum Kind { case down, up, move, wheel }
    var device: Int32
    var kind: Kind
    var button: Int
    var time: Double
    var point: CGPoint = .zero
    var dx: Double = 0
    var dy: Double = 0
    var modifiers: UInt64 = 0
    var app = ""
    var original: CGEvent?
    var physicalWheelSign: Int?
}
enum SMEffect {
    case replay([SMInput])
    case action(SMRule, String)
    case continuous(SMAction, Int32, CGPoint, Int) // phase: 1 began, 2 changed, 4 ended, 8 cancelled
    case wheel(SMAction, SMInput)
    case trail(Int32, [CGPoint], String?)
    case hideTrail(Int32)
}
struct SMDecision { var consume = false; var effects: [SMEffect] = [] }

/// All access is confined to the event thread. Pure decisions can be tested without a live event tap.
final class SMInterpreter {
    struct Key: Hashable { var device: Int32; var button: Int }
    final class Session {
        var down: SMInput
        let config: SMConfiguration
        let rules: [SMRule]
        var heldAtStart: [SMHeldButton] = []
        var buffer: [SMInput] = []
        var count = 1
        var pressed = true
        var releasedAt: Double?
        var consumed = false
        var path = ""
        var anchor: CGPoint
        var position: CGPoint
        var lastEventPoint: CGPoint
        var points: [CGPoint] = []
        var continuous: SMAction?
        var lastWheel = -Double.infinity
        var firedWheels = Set<UUID>()
        var wheelMode = false
        var nativeDrag = false
        init(_ input: SMInput, config: SMConfiguration, rules: [SMRule]) {
            down = input; self.config = config; self.rules = rules; anchor = input.point; position = input.point
            lastEventPoint = input.point; points = [input.point]
        }
    }
    private var sessions: [Key: Session] = [:]
    var activeCount: Int { sessions.count }
    private func eligible(_ config: SMConfiguration, app: String) -> [SMRule] {
        config.rules.enumerated().filter {
            $0.element.enabled && $0.element.filter.matches(app)
                && ($0.element.trigger.button >= 3 ? config.resolvedSideButtonsEnabled : config.resolvedGesturesEnabled)
        }
            .sorted { a, b in
                a.element.filter.priority == b.element.filter.priority ? a.offset < b.offset : a.element.filter.priority > b.element.filter.priority
            }.map(\.element)
    }
    private func matches(_ rule: SMRule, session: Session, device: Int32, kind: SMTrigger.Kind) -> Bool {
        let t = rule.trigger
        return t.button == session.down.button && t.kind == kind && t.clicks == session.count &&
            t.modifiers == session.down.modifiers && t.held.allSatisfy { session.heldAtStart.contains($0) }
    }
    private func first(_ session: Session, device: Int32, kind: SMTrigger.Kind) -> SMRule? {
        session.rules.first { matches($0, session: session, device: device, kind: kind) }
    }
    private func claimPrefixes(_ rule: SMRule, device: Int32) {
        for h in rule.trigger.held { sessions[Key(device: device, button: h.button)]?.consumed = true }
    }
    func process(_ input: SMInput, configuration: SMConfiguration) -> SMDecision {
        var result = tick(input.time)
        let key = Key(device: input.device, button: input.button)
        switch input.kind {
        case .down:
            if let s = sessions[key], !s.pressed, let at = s.releasedAt,
               input.time - at <= s.config.clickInterval, input.app == s.down.app, input.modifiers == s.down.modifiers {
                s.count += 1; s.pressed = true; s.releasedAt = nil; s.down.time = input.time
                s.buffer.append(input); s.anchor = input.point; s.position = input.point; s.lastEventPoint = input.point
                result.consume = true; return result
            }
            if let s = sessions.removeValue(forKey: key) { finishClick(s, key: key, into: &result) }
            let rules = eligible(configuration, app: input.app)
            let relevant = rules.filter { r in
                (r.trigger.button == input.button && r.trigger.modifiers == input.modifiers && r.trigger.held.allSatisfy { h in
                    let s = sessions[Key(device: input.device, button: h.button)]
                    return s?.pressed == true && s?.count == h.clicks
                }) || r.trigger.held.contains(where: { $0.button == input.button })
            }
            guard !relevant.isEmpty else { return result }
            let s = Session(input, config: configuration, rules: relevant); s.buffer = [input]; sessions[key] = s
            s.heldAtStart = sessions.filter { $0.key.device == input.device && $0.key != key && $0.value.pressed }
                .map { SMHeldButton(button: $0.key.button, clicks: $0.value.count) }
            for rule in relevant where rule.trigger.button == input.button { claimPrefixes(rule, device: input.device) }
            result.consume = true
        case .up:
            guard let s = sessions[key] else { return result }
            result.consume = !s.nativeDrag
            s.pressed = false; s.releasedAt = input.time
            if s.nativeDrag { sessions.removeValue(forKey: key); return result }
            s.buffer.append(input)
            if let action = s.continuous { result.effects.append(.continuous(action, input.device, .zero, 4)) }
            if !s.path.isEmpty {
                if let rule = s.rules.first(where: { matches($0, session: s, device: input.device, kind: .trail) && $0.trigger.path == s.path }) {
                    result.effects.append(.action(rule, s.down.app)); claimPrefixes(rule, device: input.device)
                }
                s.consumed = true
            }
            result.effects.append(.hideTrail(input.device))
            let expectsMore = !s.consumed && s.rules.contains { r in
                (r.trigger.button == input.button && r.trigger.clicks > s.count) || r.trigger.held.contains { $0.button == input.button && $0.clicks > s.count }
            }
            if !expectsMore {
                finishClick(s, key: key, into: &result); sessions.removeValue(forKey: key)
            }
        case .move:
            for (k, s) in sessions where k.device == input.device && s.pressed {
                if s.nativeDrag { continue }
                // Only the device owning a pressed button can advance its interaction.
                result.consume = true
                if s.wheelMode { continue }
                if let action = s.continuous {
                    result.effects.append(.continuous(action, input.device, CGPoint(x: input.dx, y: input.dy), 2)); continue
                }
                if s.consumed && s.path.isEmpty { continue }
                if input.original != nil {
                    let eventDX = input.point.x - s.lastEventPoint.x
                    let eventDY = input.point.y - s.lastEventPoint.y
                    s.lastEventPoint = input.point
                    if eventDX != 0 || eventDY != 0 {
                        s.position.x += eventDX; s.position.y += eventDY
                    } else {
                        // At a screen edge the event location can stop while HID deltas continue.
                        s.position.x += input.dx; s.position.y += input.dy
                    }
                } else if input.dx != 0 || input.dy != 0 {
                    s.position.x += input.dx; s.position.y += input.dy
                } else {
                    s.position = input.point
                }
                let dx = s.position.x - s.anchor.x, dy = s.position.y - s.anchor.y
                guard hypot(dx, dy) >= s.config.trailThreshold else { continue }
                if let rule = first(s, device: k.device, kind: .drag) {
                    s.continuous = rule.action; s.consumed = true; claimPrefixes(rule, device: k.device)
                    result.effects.append(.continuous(rule.action, input.device, CGPoint(x: dx, y: dy), 1))
                } else if s.rules.contains(where: { matches($0, session: s, device: k.device, kind: .trail) }) {
                    let direction = abs(dx) > abs(dy) ? (dx > 0 ? "R" : "L") : (dy > 0 ? "D" : "U")
                    if s.path.last.map(String.init) != direction, s.path.count < 32 { s.path += direction }
                    s.anchor = s.position; s.points.append(s.position)
                    if s.points.count > 512 { s.points.removeFirst(s.points.count - 512) }
                    if s.config.showTrail || s.config.resolvedShowGestureLabel {
                        let label = s.rules.first {
                            matches($0, session: s, device: k.device, kind: .trail) && $0.trigger.path == s.path
                        }?.displayName
                        result.effects.append(.trail(input.device, s.points, label))
                    }
                } else {
                    // No drag action applies: restore the native down stream and stop intercepting the drag.
                    result.effects.append(.replay(s.buffer)); s.buffer.removeAll(); s.nativeDrag = true; result.consume = false
                }
            }
        case .wheel:
            // Most recently pressed eligible button owns the wheel; never combine across devices.
            let candidates = sessions.filter { $0.key.device == input.device && $0.value.pressed }
                .sorted { $0.value.down.time > $1.value.down.time }
            for (k, s) in candidates {
                guard !s.nativeDrag, s.path.isEmpty, s.continuous == nil else { continue }
                guard input.dy != 0 else { continue }
                let kind: SMTrigger.Kind = (input.physicalWheelSign ?? (input.dy > 0 ? 1 : -1)) > 0 ? .wheelUp : .wheelDown
                guard let rule = first(s, device: k.device, kind: kind) else { continue }
                s.wheelMode = true; s.consumed = true; result.consume = true; claimPrefixes(rule, device: k.device)
                if rule.action.kind.rawValue.hasPrefix("wheel") {
                    result.effects.append(.wheel(rule.action, input)); return result
                }
                if (!rule.wheelRepeat && s.firedWheels.contains(rule.id)) || input.time - s.lastWheel < rule.wheelInterval { return result }
                s.lastWheel = input.time; s.firedWheels.insert(rule.id)
                result.effects.append(.action(rule, s.down.app)); return result
            }
        }
        return result
    }
    func tick(_ time: Double) -> SMDecision {
        var result = SMDecision()
        for (key, s) in Array(sessions) {
            if s.pressed && !s.consumed && s.path.isEmpty && !s.nativeDrag && time - s.down.time >= s.config.holdDelay,
               let rule = first(s, device: key.device, kind: .hold) {
                s.consumed = true; claimPrefixes(rule, device: key.device); result.effects.append(.action(rule, s.down.app))
            }
            if let at = s.releasedAt, time - at >= s.config.clickInterval {
                finishClick(s, key: key, into: &result); sessions.removeValue(forKey: key)
            }
        }
        return result
    }
    private func finishClick(_ s: Session, key: Key, into result: inout SMDecision) {
        guard !s.consumed else { return }
        if let rule = first(s, device: key.device, kind: .click) {
            claimPrefixes(rule, device: key.device); result.effects.append(.action(rule, s.down.app))
        } else { result.effects.append(.replay(s.buffer)) }
    }
    func cancelUnidentifiedRelease(button: Int) -> SMDecision {
        var result = SMDecision()
        for (key, s) in Array(sessions) where key.button == button {
            if let action = s.continuous { result.effects.append(.continuous(action, key.device, .zero, 8)) }
            result.effects.append(.hideTrail(key.device)); sessions.removeValue(forKey: key)
        }
        return result
    }
    func cancel(device: Int32? = nil, gesturesOnly: Bool = false, sideButtonsOnly: Bool = false) -> SMDecision {
        var result = SMDecision()
        for (key, s) in Array(sessions) where device == nil || key.device == device {
            if gesturesOnly && key.button >= 3 { continue }
            if sideButtonsOnly && key.button < 3 { continue }
            if let action = s.continuous { result.effects.append(.continuous(action, key.device, .zero, 8)) }
            result.effects.append(.hideTrail(key.device))
            // A swallowed physical down must never leave an application with an unmatched down.
            // Replaying on cancellation would fire phantom clicks during lock/sleep, so discard pending input.
            sessions.removeValue(forKey: key)
        }
        return result
    }
}
