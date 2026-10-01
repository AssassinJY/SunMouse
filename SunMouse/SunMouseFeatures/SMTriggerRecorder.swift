import AppKit
import SwiftUI

/// Runs under the recorder lock, independently of the user's configured actions.
struct SMTriggerRecordingEngine {
    var trigger: SMTrigger?
    private var pressed: [Int: (count: Int, time: Double)] = [:]
    private var counts: [Int: Int] = [:]
    private var releasedAt: Double?
    private var displacement = CGPoint.zero
    let clickInterval: Double
    let holdDelay: Double

    init(clickInterval: Double = 0.3, holdDelay: Double = 0.45) {
        self.clickInterval = clickInterval; self.holdDelay = holdDelay
    }
    var hasPressedButtons: Bool { !pressed.isEmpty }
    mutating func process(_ input: SMInput) {
        switch input.kind {
        case .down:
            guard (1...4).contains(input.button) else { return }
            if let releasedAt, input.time - releasedAt > clickInterval { counts.removeAll() }
            let count = min(3, (counts[input.button] ?? 0) + 1)
            counts[input.button] = count
            var next = SMTrigger(); next.button = input.button; next.clicks = count
            next.modifiers = input.modifiers
            next.held = pressed.sorted { $0.key < $1.key }.map { .init(button: $0.key, clicks: $0.value.count) }
            trigger = next; pressed[input.button] = (count, input.time)
            displacement = .zero; releasedAt = nil
        case .move:
            guard let trigger, pressed[trigger.button] != nil, ![.wheelUp, .wheelDown].contains(trigger.kind) else { return }
            displacement.x += input.dx; displacement.y += input.dy
            if hypot(displacement.x, displacement.y) >= 18 { self.trigger?.kind = .drag }
        case .wheel:
            guard hasPressedButtons, input.dy != 0 else { return }
            trigger?.kind = (input.physicalWheelSign ?? (input.dy > 0 ? 1 : -1)) > 0 ? .wheelUp : .wheelDown
        case .up:
            if let down = pressed[input.button], trigger?.button == input.button,
               trigger?.kind == .click, input.time - down.time >= holdDelay { trigger?.kind = .hold }
            pressed.removeValue(forKey: input.button)
            if pressed.isEmpty { releasedAt = input.time }
        }
    }
    func completed(at time: Double) -> SMTrigger? {
        guard let releasedAt, time - releasedAt >= clickInterval, let trigger, trigger.button >= 3 else { return nil }
        return trigger
    }
}

final class SMTriggerRecorder: ObservableObject {
    static let shared = SMTriggerRecorder()
    @Published private(set) var preview: SMTrigger?
    private let lock = NSLock()
    private var engine: SMTriggerRecordingEngine?
    private var deviceID: Int32?
    private var timer: Timer?
    private var completion: ((SMTrigger) -> Void)?

    func start(completion: @escaping (SMTrigger) -> Void) {
        stop()
        EventThread.shared.perform { SMRuntime.shared.cancel() }
        let config = SMRuleStore.shared.configuration
        lock.withLock { engine = SMTriggerRecordingEngine(clickInterval: config.clickInterval, holdDelay: config.holdDelay) }
        self.completion = completion
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.update() }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        lock.withLock { engine = nil; deviceID = nil }
        completion = nil; preview = nil
    }
    private func update() {
        let state = lock.withLock { (engine?.trigger, engine?.completed(at: ProcessInfo.processInfo.systemUptime)) }
        preview = state.0
        if let trigger = state.1 {
            let callback = completion
            stop(); callback?(trigger)
        }
    }
    /// Called before rule execution, so recording an existing binding cannot run its action.
    func capture(_ event: CGEvent, device: Int32) -> Bool {
        lock.withLock {
            guard engine != nil, deviceID == nil || deviceID == device else { return false }
            let kind: SMInput.Kind
            switch event.type {
            case .rightMouseDown, .otherMouseDown: kind = .down
            case .rightMouseUp, .otherMouseUp: kind = .up
            case .mouseMoved, .rightMouseDragged, .otherMouseDragged:
                guard engine?.hasPressedButtons == true else { return false }; kind = .move
            case .scrollWheel:
                guard engine?.hasPressedButtons == true else { return false }; kind = .wheel
            default: return false
            }
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            if kind == .down || kind == .up { guard (1...4).contains(button) else { return false } }
            if kind == .down { deviceID = device }
            let dy = kind == .wheel ? SMRuntime.wheelDelta(event) : Double(event.getIntegerValueField(.mouseEventDeltaY))
            engine?.process(SMInput(device: device, kind: kind, button: button,
                time: ProcessInfo.processInfo.systemUptime, dx: Double(event.getIntegerValueField(.mouseEventDeltaX)), dy: dy,
                modifiers: event.flags.rawValue & SMConfiguration.modifierMask,
                physicalWheelSign: kind == .wheel ? (dy > 0 ? 1 : -1) * ((NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false) ? -1 : 1) : nil))
            return true
        }
    }
}

struct SMAddButtonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var recorder = SMTriggerRecorder.shared
    @State private var captured: SMTrigger?
    let add: (SMTrigger) -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "computermouse").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("操作要配置的侧键").font(.title2.bold())
            Text("单击、双击、长按，或按住侧键拖动／滚动。\n也可以同时按住修饰键或另一个鼠标按钮。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text((captured ?? recorder.preview).map(smTriggerLabel) ?? "等待鼠标操作…").font(.headline).frame(height: 32)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let captured {
                    Button("重新录制") { self.captured = nil; start() }
                    Button("选择动作") { add(captured); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 460)
        .onAppear(perform: start)
        .onDisappear { recorder.stop() }
    }
    private func start() { recorder.start { captured = $0 } }
}

func smTriggerLabel(_ trigger: SMTrigger) -> String {
    let flags = CGEventFlags(rawValue: trigger.modifiers)
    let modifiers = (flags.contains(.maskControl) ? "⌃" : "") + (flags.contains(.maskAlternate) ? "⌥" : "") +
        (flags.contains(.maskShift) ? "⇧" : "") + (flags.contains(.maskCommand) ? "⌘" : "")
    let held = trigger.held.map { smButtonName($0.button) + ($0.clicks > 1 ? "（\($0.clicks) 次后按住）" : "按住") }.joined(separator: "＋")
    let clicks = trigger.clicks == 1 ? "" : "\(trigger.clicks) 次"
    return [modifiers, held, smButtonName(trigger.button), clicks + trigger.kind.label,
            trigger.kind == .trail ? smPathLabel(trigger.path) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
}
