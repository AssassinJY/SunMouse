import AppKit
import Carbon.HIToolbox

// SunMouse's global rules are independent of device-specific pointer/scroll schemes.
struct SMAppFilter: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case all, only, except }
    var mode: Mode = .all
    var applications: [String] = []
    func matches(_ app: String) -> Bool {
        switch mode {
        case .all: return true
        case .only: return applications.contains(app)
        case .except: return !applications.contains(app)
        }
    }
    var priority: Int { mode == .only ? 2 : mode == .except ? 1 : 0 }
}
struct SMHeldButton: Codable, Equatable, Hashable {
    var button: Int
    var clicks: Int = 1
}
struct SMTrigger: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case click, hold, drag, wheelUp, wheelDown, trail }
    var button = 3 // CG numbering: right 1, middle 2, side buttons 3 and 4.
    var clicks = 1
    var kind: Kind = .click
    var modifiers: UInt64 = 0
    var held: [SMHeldButton] = []
    var path = "R"
}
struct SMAction: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case shortcut, script, builtin, dragScroll, dragSpaces, wheelZoom, wheelHorizontal, wheelQuick, wheelPrecise, wheelRotate, wheelSpaces, wheelPinch }
    var kind: Kind = .shortcut
    var keyCode: UInt16 = 0
    var modifiers: UInt64 = CGEventFlags.maskCommand.rawValue
    var shortcutLabel = "⌘A"
    var script = ""
    var builtin = "mouse.button.back"

    var displayLabel: String {
        switch kind {
        case .shortcut:
            return resolvedShortcutLabel
        case .script:
            return "AppleScript"
        case .builtin:
            return Scheme.Buttons.Mapping.Action.Arg0(rawValue: builtin)
                .map { Scheme.Buttons.Mapping.Action.arg0($0).description } ?? builtin
        case .dragScroll:
            return "滚动与导航"
        case .dragSpaces:
            return "空间与 Mission Control"
        case .wheelZoom:
            return "放大或缩小"
        case .wheelHorizontal:
            return "横向滚动"
        case .wheelQuick:
            return "快速滚动"
        case .wheelPrecise:
            return "精细滚动"
        case .wheelRotate:
            return "旋转"
        case .wheelSpaces:
            return "切换空间"
        case .wheelPinch:
            return "桌面与启动台"
        }
    }

    var resolvedShortcutLabel: String {
        Self.formattedShortcutLabel(
            keyCode: keyCode,
            modifiers: modifiers,
            fallbackKey: String(shortcutLabel.drop(while: { "⌃⌥⇧⌘".contains($0) }))
        )
    }

    static func formattedShortcutLabel(keyCode: UInt16, modifiers: UInt64, fallbackKey: String?) -> String {
        let modifierLabel = (modifiers & CGEventFlags.maskControl.rawValue != 0 ? "⌃" : "")
            + (modifiers & CGEventFlags.maskAlternate.rawValue != 0 ? "⌥" : "")
            + (modifiers & CGEventFlags.maskShift.rawValue != 0 ? "⇧" : "")
            + (modifiers & CGEventFlags.maskCommand.rawValue != 0 ? "⌘" : "")
        let keyLabel: String
        switch Int(keyCode) {
        case kVK_Return: keyLabel = "↩"
        case kVK_Tab: keyLabel = "⇥"
        case kVK_Space: keyLabel = "Space"
        case kVK_Delete: keyLabel = "⌫"
        case kVK_Escape: keyLabel = "Esc"
        case kVK_ForwardDelete: keyLabel = "⌦"
        case kVK_Home: keyLabel = "Home"
        case kVK_End: keyLabel = "End"
        case kVK_PageUp: keyLabel = "Page Up"
        case kVK_PageDown: keyLabel = "Page Down"
        case kVK_LeftArrow: keyLabel = "←"
        case kVK_RightArrow: keyLabel = "→"
        case kVK_DownArrow: keyLabel = "↓"
        case kVK_UpArrow: keyLabel = "↑"
        case kVK_F1: keyLabel = "F1"
        case kVK_F2: keyLabel = "F2"
        case kVK_F3: keyLabel = "F3"
        case kVK_F4: keyLabel = "F4"
        case kVK_F5: keyLabel = "F5"
        case kVK_F6: keyLabel = "F6"
        case kVK_F7: keyLabel = "F7"
        case kVK_F8: keyLabel = "F8"
        case kVK_F9: keyLabel = "F9"
        case kVK_F10: keyLabel = "F10"
        case kVK_F11: keyLabel = "F11"
        case kVK_F12: keyLabel = "F12"
        case kVK_F13: keyLabel = "F13"
        case kVK_F14: keyLabel = "F14"
        case kVK_F15: keyLabel = "F15"
        case kVK_F16: keyLabel = "F16"
        case kVK_F17: keyLabel = "F17"
        case kVK_F18: keyLabel = "F18"
        case kVK_F19: keyLabel = "F19"
        case kVK_F20: keyLabel = "F20"
        default:
            let fallback = fallbackKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            keyLabel = fallback.isEmpty ? "Key \(keyCode)" : fallback.uppercased()
        }
        return modifierLabel + keyLabel
    }
}

extension SMAction.Kind {
    var isWheelAction: Bool {
        switch self {
        case .wheelZoom, .wheelHorizontal, .wheelQuick, .wheelPrecise,
             .wheelRotate, .wheelSpaces, .wheelPinch:
            return true
        default:
            return false
        }
    }
}

extension SMTrigger.Kind {
    var compatibleActionKinds: [SMAction.Kind] {
        switch self {
        case .drag:
            return [.dragScroll, .dragSpaces]
        case .wheelUp, .wheelDown:
            return [
                .wheelZoom, .wheelHorizontal, .wheelQuick, .wheelPrecise,
                .wheelRotate, .wheelSpaces, .wheelPinch,
                .builtin, .shortcut, .script
            ]
        case .click, .hold, .trail:
            return [.builtin, .shortcut, .script]
        }
    }

    var defaultActionKind: SMAction.Kind {
        compatibleActionKinds[0]
    }

    func supportsRepeatConfiguration(for actionKind: SMAction.Kind) -> Bool {
        switch self {
        case .wheelUp, .wheelDown:
            return !actionKind.isWheelAction
        default:
            return false
        }
    }
}

struct SMRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "新规则"
    var enabled = true
    var trigger = SMTrigger()
    var filter = SMAppFilter()
    var action = SMAction()
    var wheelRepeat = true
    var wheelInterval = 0.12

    var hasCustomName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "新规则"
    }

    var displayName: String {
        hasCustomName ? name.trimmingCharacters(in: .whitespacesAndNewlines) : action.displayLabel
    }
}
struct SMConfiguration: Codable, Equatable {
    var version = 1
    var rules: [SMRule] = []
    var trailThreshold = 18.0
    var holdDelay = 0.45
    var clickInterval = 0.3
    var showTrail = true
    var gesturesEnabled: Bool?
    var sideButtonsEnabled: Bool?
    var trailWidth: Double?
    var trailColorHex: String?
    var showGestureLabel: Bool?
    var gestureLabelFontSize: Double?
    var gestureLabelColorHex: String?
    var gestureLabelBackgroundColorHex: String?
    var gestureLabelPosition: SMGestureLabelPosition?

    var resolvedTrailWidth: Double { trailWidth ?? 4 }
    var resolvedGesturesEnabled: Bool { gesturesEnabled ?? true }
    var resolvedSideButtonsEnabled: Bool { sideButtonsEnabled ?? true }
    var resolvedTrailColorHex: String { trailColorHex ?? "007AFFD9" }
    var resolvedShowGestureLabel: Bool { showGestureLabel ?? true }
    var resolvedGestureLabelFontSize: Double { gestureLabelFontSize ?? 36 }
    var resolvedGestureLabelColorHex: String { gestureLabelColorHex ?? "FFFFFFFF" }
    var resolvedGestureLabelBackgroundColorHex: String { gestureLabelBackgroundColorHex ?? "000000B8" }
    var resolvedGestureLabelPosition: SMGestureLabelPosition { gestureLabelPosition ?? .center }

    func validated() throws -> Self {
        guard version == 1, (4...100).contains(trailThreshold), (0.15...2).contains(holdDelay),
              (0.15...1).contains(clickInterval), rules.count <= 1000,
              (1...20).contains(resolvedTrailWidth),
              Self.isValidColorHex(resolvedTrailColorHex),
              (10...48).contains(resolvedGestureLabelFontSize),
              Self.isValidColorHex(resolvedGestureLabelColorHex),
              Self.isValidColorHex(resolvedGestureLabelBackgroundColorHex),
              Set(rules.map(\.id)).count == rules.count else { throw SMError.invalidConfiguration }
        for rule in rules {
            let t = rule.trigger
            guard (1...4).contains(t.button), (1...3).contains(t.clicks),
                  t.held.allSatisfy({ (1...4).contains($0.button) && $0.button != t.button && (1...3).contains($0.clicks) }),
                  Set(t.held.map(\.button)).count == t.held.count,
                  t.modifiers & ~Self.modifierMask == 0,
                  rule.action.modifiers & ~Self.modifierMask == 0,
                  (0.04...2).contains(rule.wheelInterval),
                  rule.action.keyCode < 128 else { throw SMError.invalidConfiguration }
            if t.kind == .trail {
                guard !t.path.isEmpty, t.path.count <= 32,
                      t.path.allSatisfy({ "UDLR".contains($0) }) else { throw SMError.invalidConfiguration }
            }
            guard t.kind.compatibleActionKinds.contains(rule.action.kind),
                  t.kind != .trail || t.button == 1,
                  rule.action.kind != .builtin || Scheme.Buttons.Mapping.Action.Arg0(rawValue: rule.action.builtin) != nil else { throw SMError.invalidConfiguration }
        }
        return self
    }
    private static func isValidColorHex(_ value: String) -> Bool {
        value.count == 8 && UInt64(value, radix: 16) != nil
    }
    mutating func installDefaultSideButtonRulesIfNeeded() {
        guard !rules.contains(where: { $0.trigger.button >= 3 }) else { return }
        rules.append(contentsOf: Self.defaultSideButtonRules())
    }
    static func defaultSideButtonRules() -> [SMRule] {
        func rule(button: Int, trigger: SMTrigger.Kind, action: SMAction.Kind, builtin: String = "mouse.button.back", name: String) -> SMRule {
            var rule = SMRule()
            rule.name = name
            rule.trigger.button = button
            rule.trigger.kind = trigger
            rule.action.kind = action
            rule.action.builtin = builtin
            return rule
        }

        return [
            rule(button: 3, trigger: .click, action: .builtin, builtin: "lookUpAndDataDetectors", name: "查询与快速查看"),
            rule(button: 3, trigger: .wheelUp, action: .wheelPinch, name: "桌面与启动台"),
            rule(button: 3, trigger: .wheelDown, action: .wheelPinch, name: "桌面与启动台"),
            rule(button: 3, trigger: .drag, action: .dragSpaces, name: "空间与 Mission Control"),
            rule(button: 4, trigger: .click, action: .builtin, builtin: "smartZoom", name: "智能缩放"),
            rule(button: 4, trigger: .wheelUp, action: .wheelZoom, name: "放大或缩小"),
            rule(button: 4, trigger: .wheelDown, action: .wheelZoom, name: "放大或缩小"),
            rule(button: 4, trigger: .drag, action: .dragScroll, name: "滚动与导航")
        ]
    }
    static let modifierMask = CGEventFlags([.maskCommand, .maskShift, .maskControl, .maskAlternate]).rawValue
    var conflicts: [String] {
        var result: [String] = []
        for (i, a) in rules.enumerated() where a.enabled {
            for b in rules.dropFirst(i + 1) where b.enabled && a.trigger == b.trigger {
                let overlap = a.filter.mode == .all || b.filter.mode == .all ||
                    a.filter.mode == .except || b.filter.mode == .except ||
                    !Set(a.filter.applications).isDisjoint(with: b.filter.applications)
                if overlap { result.append("「\(a.name)」与「\(b.name)」可能重叠；指定应用优先，同级按列表顺序。") }
            }
        }
        return result
    }
}

enum SMGestureLabelPosition: String, Codable, CaseIterable, Equatable {
    case center
    case topLeft
    case topCenter
    case topRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var label: String {
        switch self {
        case .center: "中央"
        case .topLeft: "左上"
        case .topCenter: "上中"
        case .topRight: "右上"
        case .bottomLeft: "左下"
        case .bottomCenter: "下中"
        case .bottomRight: "右下"
        }
    }
}
enum SMError: LocalizedError {
    case invalidConfiguration
    var errorDescription: String? { "配置格式或规则组合无效，请检查后重试。" }
}

final class SMRuleStore: ObservableObject {
    static let shared = SMRuleStore()
    @Published var configuration = SMConfiguration() { didSet { publishAndSave() } }
    @Published var lastError: String?
    @Published var paused = false
    private let lock = NSLock()
    private var snapshotValue = SMConfiguration()
    private var loading = false
    private var needsRecoveryBackup = false
    let url: URL
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SunMouse/rules.json")) {
        self.url = url
        loading = true
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                configuration = try JSONDecoder().decode(SMConfiguration.self, from: Data(contentsOf: url)).validated()
                snapshotValue = configuration
            } else {
                configuration = try SMDefaultConfiguration.load().rules
                snapshotValue = configuration
                loading = false
                publishAndSave()
                return
            }
        } catch {
            lastError = error.localizedDescription
            needsRecoveryBackup = true
            loading = false
            // Do not replace unreadable user rules with defaults during launch.
            return
        }
        loading = false
        installDefaultSideButtonRulesIfNeeded()
    }
    func snapshot() -> SMConfiguration { lock.lock(); defer { lock.unlock() }; return snapshotValue }
    private func publishAndSave() {
        guard !loading else { return }
        do {
            let config = try configuration.validated()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if needsRecoveryBackup {
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("rules-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: backup)
                needsRecoveryBackup = false
            }
            try data.write(to: url, options: .atomic)
            lock.lock(); snapshotValue = config; lock.unlock()
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }
    private func installDefaultSideButtonRulesIfNeeded() {
        var updated = configuration
        updated.installDefaultSideButtonRulesIfNeeded()
        if updated != configuration {
            configuration = updated
        }
    }
    struct Backup: Codable { var version = 1; var rules: SMConfiguration; var devices: Configuration }
    func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "SunMouse.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Backup(rules: configuration, devices: ConfigurationState.shared.configuration)).write(to: url, options: .atomic)
        } catch { lastError = error.localizedDescription }
    }
    func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: url))
            guard backup.version == 1 else { throw SMError.invalidConfiguration }
            let validated = try backup.rules.validated()
            // Preserve the previous complete configuration before replacement.
            try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            try encoder.encode(Backup(rules: configuration, devices: ConfigurationState.shared.configuration))
                .write(to: self.url.deletingLastPathComponent().appendingPathComponent("before-import.json"), options: .atomic)
            configuration = validated
            ConfigurationState.shared.configuration = backup.devices
        } catch { lastError = error.localizedDescription }
    }
}
