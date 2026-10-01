import SwiftUI
import UniformTypeIdentifiers

extension SMTrigger.Kind {
    var label: String { switch self { case .click: return "点击"; case .hold: return "按住"; case .drag: return "按住拖动"; case .wheelUp: return "按住＋滚轮向上"; case .wheelDown: return "按住＋滚轮向下"; case .trail: return "右键轨迹" } }
}
extension SMAction.Kind {
    var label: String { switch self {
    case .shortcut: return "快捷键"; case .script: return "AppleScript"; case .builtin: return "系统与鼠标动作"
    case .dragScroll: return "滚动与导航"; case .dragSpaces: return "空间与 Mission Control"
    case .wheelZoom: return "放大或缩小"; case .wheelHorizontal: return "横向滚动"; case .wheelQuick: return "快速滚动"
    case .wheelPrecise: return "精细滚动"; case .wheelRotate: return "旋转"; case .wheelSpaces: return "切换空间"; case .wheelPinch: return "桌面与启动台"
    } }
}
func smButtonName(_ button: Int) -> String { [1: "右键", 2: "中键", 3: "侧键 1", 4: "侧键 2"][button] ?? "按钮 \(button)" }
func smPathLabel(_ path: String) -> String { path.map { ["U":"↑", "D":"↓", "L":"←", "R":"→"][$0] ?? String($0) }.joined(separator: " ") }

struct SMRulesView: View {
    let sideButtons: Bool
    @ObservedObject private var store = SMRuleStore.shared
    @ObservedObject private var recorder = SMTriggerRecorder.shared
    @State private var editing: SMRule?
    @State private var captureActive = false
    @State private var captureMessage: String?
    @State private var showOptions = false
    @State private var showTrailAppearance = false
    @State private var showRestoreConfirmation = false
    private var rules: [SMRule] { store.configuration.rules.filter { ($0.trigger.button >= 3) == sideButtons } }
    var body: some View {
        Group {
            if sideButtons { sideButtonBody }
            else { gestureBody }
        }
        .sheet(item: $editing) { rule in SMRuleEditor(rule: rule) { updated in
            saveRule(updated)
        } }
        .sheet(isPresented: $showTrailAppearance) { trailAppearanceSheet }
        .onDisappear { if sideButtons { recorder.stop() } }
    }

    private var sideButtonBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("启用侧键", isOn: Binding(
                    get: { store.configuration.resolvedSideButtonsEnabled },
                    set: { store.configuration.sideButtonsEnabled = $0 }
                ))
                captureField
                Text("将鼠标指针移到“+”区域内，然后操作要配置的侧键。\n也可以连续点击、按住并滚动或按住并拖移。")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if rules.isEmpty {
                    Text("尚未添加侧键操作")
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .foregroundStyle(.secondary)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                } else {
                    sideButtonTable
                }

                ForEach(Array(store.configuration.conflicts.prefix(3).enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack {
                    Button("选项…") { showOptions.toggle() }
                        .popover(isPresented: $showOptions) { sideButtonOptions }
                    Spacer()
                    Button("恢复默认值…") { showRestoreConfirmation = true }
                }
                if let error = store.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .confirmationDialog("恢复默认侧键设置？", isPresented: $showRestoreConfirmation, titleVisibility: .visible) {
            Button("恢复默认值", role: .destructive, action: restoreDefaultSideButtons)
        } message: {
            Text("这会删除当前所有侧键规则，并恢复查询、缩放、桌面与导航等六项默认操作。")
        }
    }

    private var captureField: some View {
        Button(action: startCapture) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 8)
                    .stroke(captureActive ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: captureActive ? 2 : 1)
                VStack(spacing: 4) {
                    Image(systemName: captureActive ? "computermouse.fill" : "plus")
                        .font(.system(size: captureActive ? 24 : 30, weight: .regular))
                    if captureActive {
                        Text(recorder.preview.map(smTriggerLabel) ?? "等待侧键操作…")
                            .font(.subheadline)
                    } else if let captureMessage {
                        Text(captureMessage).font(.subheadline)
                    }
                }
                .foregroundStyle(captureActive ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在此区域内操作要配置的侧键")
        .onHover { inside in
            if inside, !captureActive { startCapture() }
            else if !inside, captureActive { stopCapture() }
        }
    }

    private var sideButtonTable: some View {
        VStack(spacing: 0) {
            ForEach(sideButtonNumbers, id: \.self) { button in
                let displayedRules = displayRulesForButton(button)
                Text(smButtonName(button))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                ForEach(displayedRules) { rule in
                    sideButtonRow(rule)
                    if rule.id != displayedRules.last?.id { Divider() }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func sideButtonRow(_ rule: SMRule) -> some View {
        HStack(spacing: 10) {
            Button {
                removeRuleAndPair(rule)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("删除操作")

            Text(compactTriggerLabel(rule.trigger, combinesWheelDirections: pairedWheelRule(for: rule) != nil))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            SMActionMenu(rule: rule, select: { action in
                updateAction(action, for: rule)
            })
            .frame(minWidth: 230, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.5)
        .contextMenu {
            Button(rule.enabled ? "停用" : "启用") {
                setEnabled(!rule.enabled, for: rule)
            }
        }
    }

    private var sideButtonOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("侧键选项").font(.headline)
            HStack {
                Text("多击间隔")
                Slider(value: $store.configuration.clickInterval, in: 0.15...1).frame(width: 150)
                Text(String(format: "%.2f 秒", store.configuration.clickInterval)).monospacedDigit()
            }
            HStack {
                Text("长按阈值")
                Slider(value: $store.configuration.holdDelay, in: 0.15...2).frame(width: 150)
                Text(String(format: "%.2f 秒", store.configuration.holdDelay)).monospacedDigit()
            }
        }
        .padding(18)
    }

    private var gestureBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("启用手势", isOn: Binding(
                get: { store.configuration.resolvedGesturesEnabled },
                set: { store.configuration.gesturesEnabled = $0 }
            ))
            HStack {
                Text("右键轨迹、右键滚轮与右键／中键单击。")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    var rule = SMRule(); rule.trigger.button = 1; rule.trigger.kind = .trail; rule.trigger.path = ""; editing = rule
                } label: { Label("添加手势", systemImage: "plus") }
            }
            if rules.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "hand.draw").font(.system(size: 42)).foregroundStyle(.secondary)
                    Text("尚未设置规则").font(.title3.bold())
                    Text("没有适用规则时，鼠标保持原有行为。").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { rule in
                        gestureRuleRow(rule)
                    }
                }
                .listStyle(.inset)
            }
            ForEach(Array(store.configuration.conflicts.prefix(3).enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            HStack(alignment: .center) {
                Text("应用以按下时的前台应用为准。轨迹或滚轮已触发后，不再执行单击。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showTrailAppearance = true
                } label: {
                    Label("轨迹外观…", systemImage: "paintpalette")
                }
            }
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func gestureRuleRow(_ rule: SMRule) -> some View {
        HStack(spacing: 14) {
            Toggle("启用", isOn: enabled(rule))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 5) {
                Text(smTriggerLabel(rule.trigger))
                    .font(.headline)
                    .lineLimit(1)
                Text(filterLabel(rule.filter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(rule.displayName)
                    .lineLimit(1)
                if rule.hasCustomName {
                    Text(actionLabel(rule.action))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 190, alignment: .leading)

            Button { editing = rule } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑规则")

            Button {
                store.configuration.rules.removeAll { $0.id == rule.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除规则")
        }
        .padding(.vertical, 7)
        .opacity(rule.enabled ? 1 : 0.55)
        .contextMenu {
            Button(rule.enabled ? "停用" : "启用") {
                setEnabled(!rule.enabled, for: rule)
            }
            Button("编辑规则…") { editing = rule }
            Divider()
            Button("删除规则", role: .destructive) {
                store.configuration.rules.removeAll { $0.id == rule.id }
            }
        }
    }

    private var trailAppearanceSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("轨迹外观")
                .font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Toggle("显示轨迹", isOn: $store.configuration.showTrail)
                    ColorPicker("轨迹颜色", selection: trailColor, supportsOpacity: true)
                }
                GridRow {
                    Toggle("显示标签", isOn: showGestureLabel)
                    HStack(spacing: 14) {
                        ColorPicker("文字", selection: gestureLabelColor, supportsOpacity: true)
                        ColorPicker("背景", selection: gestureLabelBackgroundColor, supportsOpacity: true)
                    }
                }
                GridRow {
                    Text("轨迹粗细")
                    valueSlider(value: trailWidth, range: 1...20, text: "\(Int(store.configuration.resolvedTrailWidth)) pt")
                }
                GridRow {
                    Text("标签字号")
                    valueSlider(value: gestureLabelFontSize, range: 10...48, text: "\(Int(store.configuration.resolvedGestureLabelFontSize)) pt")
                }
                GridRow {
                    Text("标签位置")
                    Picker("标签位置", selection: gestureLabelPosition) {
                        ForEach(SMGestureLabelPosition.allCases, id: \.self) { position in
                            Text(position.label).tag(position)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("识别阈值")
                    valueSlider(
                        value: $store.configuration.trailThreshold,
                        range: 4...100,
                        text: "\(Int(store.configuration.trailThreshold)) pt"
                    )
                }
            }

            HStack {
                Spacer()
                Button("完成") { showTrailAppearance = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func valueSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        text: String
    ) -> some View {
        HStack {
            Slider(value: value, in: range, step: 1)
            Text(text)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .frame(minWidth: 280)
    }

    private var sideButtonNumbers: [Int] {
        Array(Set(rules.map(\.trigger.button))).sorted()
    }
    private func rulesForButton(_ button: Int) -> [SMRule] {
        rules.filter { $0.trigger.button == button }
    }
    private func displayRulesForButton(_ button: Int) -> [SMRule] {
        rulesForButton(button).filter { rule in
            rule.trigger.kind != .wheelDown || pairedWheelRule(for: rule) == nil
        }
    }
    private func compactTriggerLabel(_ trigger: SMTrigger, combinesWheelDirections: Bool = false) -> String {
        if trigger.modifiers != 0 || !trigger.held.isEmpty { return smTriggerLabel(trigger) }
        let clicks = trigger.clicks == 1 ? "" : trigger.clicks == 2 ? "双" : "三"
        switch trigger.kind {
        case .click: return "\(clicks)点击"
        case .hold: return "\(clicks)点击并按住"
        case .drag: return "\(clicks)点击并拖移"
        case .wheelUp: return combinesWheelDirections ? "\(clicks)点击并滚动" : "\(clicks)点击并滚动 ↑"
        case .wheelDown: return combinesWheelDirections ? "\(clicks)点击并滚动" : "\(clicks)点击并滚动 ↓"
        case .trail: return "右键轨迹"
        }
    }
    private func startCapture() {
        guard !captureActive else { return }
        captureActive = true
        captureMessage = nil
        recorder.start { trigger in
            addCapturedTrigger(trigger)
            captureActive = false
        }
    }
    private func stopCapture() {
        recorder.stop()
        captureActive = false
    }
    private func addCapturedTrigger(_ trigger: SMTrigger) {
        if let existing = rules.first(where: { $0.trigger == trigger && $0.filter.mode == .all }) {
            captureMessage = "已存在：\(compactTriggerLabel(existing.trigger))"
            return
        }
        var rule = SMRule()
        rule.trigger = trigger
        rule.name = smTriggerLabel(trigger)
        switch trigger.kind {
        case .drag:
            rule.action.kind = .dragScroll
        case .wheelUp, .wheelDown:
            rule.action.kind = .wheelZoom
        default:
            rule.action.kind = .builtin
            rule.action.builtin = trigger.button == 4 ? "mouse.button.forward" : "mouse.button.back"
        }
        store.configuration.rules.append(rule)
        captureMessage = "已添加：\(smButtonName(trigger.button)) · \(compactTriggerLabel(trigger))"
    }
    private func restoreDefaultSideButtons() {
        var configuration = store.configuration
        configuration.rules.removeAll { $0.trigger.button >= 3 }
        configuration.installDefaultSideButtonRulesIfNeeded()
        store.configuration = configuration
        captureMessage = "已恢复默认侧键设置"
    }
    private func pairedWheelRule(for rule: SMRule) -> SMRule? {
        guard let oppositeKind = oppositeWheelKind(rule.trigger.kind) else { return nil }
        return rules.first { candidate in
            guard candidate.id != rule.id, candidate.trigger.kind == oppositeKind,
                  candidate.action == rule.action, candidate.filter == rule.filter,
                  candidate.enabled == rule.enabled, candidate.wheelRepeat == rule.wheelRepeat,
                  candidate.wheelInterval == rule.wheelInterval else { return false }
            var lhs = rule.trigger
            var rhs = candidate.trigger
            lhs.kind = .wheelUp
            rhs.kind = .wheelUp
            return lhs == rhs
        }
    }
    private func oppositeWheelKind(_ kind: SMTrigger.Kind) -> SMTrigger.Kind? {
        switch kind {
        case .wheelUp: return .wheelDown
        case .wheelDown: return .wheelUp
        default: return nil
        }
    }
    private func removeRuleAndPair(_ rule: SMRule) {
        let ids = Set([rule.id, pairedWheelRule(for: rule)?.id].compactMap { $0 })
        store.configuration.rules.removeAll { ids.contains($0.id) }
    }
    private func updateAction(_ action: SMAction, for rule: SMRule) {
        let ids = Set([rule.id, pairedWheelRule(for: rule)?.id].compactMap { $0 })
        for i in store.configuration.rules.indices where ids.contains(store.configuration.rules[i].id) {
            store.configuration.rules[i].action = action
        }
    }
    private func setEnabled(_ enabled: Bool, for rule: SMRule) {
        let ids = Set([rule.id, pairedWheelRule(for: rule)?.id].compactMap { $0 })
        for i in store.configuration.rules.indices where ids.contains(store.configuration.rules[i].id) {
            store.configuration.rules[i].enabled = enabled
        }
    }
    private func saveRule(_ updated: SMRule) {
        guard let index = store.configuration.rules.firstIndex(where: { $0.id == updated.id }) else {
            store.configuration.rules.append(updated)
            return
        }
        let original = store.configuration.rules[index]
        let pair = pairedWheelRule(for: original)
        store.configuration.rules[index] = updated
        guard let pair, let oppositeKind = oppositeWheelKind(updated.trigger.kind),
              let pairIndex = store.configuration.rules.firstIndex(where: { $0.id == pair.id }) else {
            if let pair { store.configuration.rules.removeAll { $0.id == pair.id } }
            return
        }
        var mirrored = updated
        mirrored.id = pair.id
        mirrored.trigger.kind = oppositeKind
        store.configuration.rules[pairIndex] = mirrored
    }
    private func enabled(_ rule: SMRule) -> Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { value in
                if let i = store.configuration.rules.firstIndex(where: { $0.id == rule.id }) {
                    store.configuration.rules[i].enabled = value
                }
            }
        )
    }
    private var trailWidth: Binding<Double> {
        Binding(
            get: { store.configuration.resolvedTrailWidth },
            set: { store.configuration.trailWidth = $0 }
        )
    }
    private var trailColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(smHex: store.configuration.resolvedTrailColorHex) ?? .controlAccentColor) },
            set: { store.configuration.trailColorHex = NSColor($0).smHex }
        )
    }
    private var showGestureLabel: Binding<Bool> {
        Binding(
            get: { store.configuration.resolvedShowGestureLabel },
            set: { store.configuration.showGestureLabel = $0 }
        )
    }
    private var gestureLabelFontSize: Binding<Double> {
        Binding(
            get: { store.configuration.resolvedGestureLabelFontSize },
            set: { store.configuration.gestureLabelFontSize = $0 }
        )
    }
    private var gestureLabelColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(smHex: store.configuration.resolvedGestureLabelColorHex) ?? .white) },
            set: { store.configuration.gestureLabelColorHex = NSColor($0).smHex }
        )
    }
    private var gestureLabelBackgroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(smHex: store.configuration.resolvedGestureLabelBackgroundColorHex) ?? .black.withAlphaComponent(0.72)) },
            set: { store.configuration.gestureLabelBackgroundColorHex = NSColor($0).smHex }
        )
    }

    private var gestureLabelPosition: Binding<SMGestureLabelPosition> {
        Binding(
            get: { store.configuration.resolvedGestureLabelPosition },
            set: { store.configuration.gestureLabelPosition = $0 }
        )
    }
    private func filterLabel(_ filter: SMAppFilter) -> String {
        switch filter.mode { case .all: return "所有应用"; case .only: return "仅 \(filter.applications.count) 个应用"; case .except: return "排除 \(filter.applications.count) 个应用" }
    }
    private func actionLabel(_ action: SMAction) -> String {
        if action.kind == .shortcut { return action.resolvedShortcutLabel }
        if action.kind == .builtin { return Scheme.Buttons.Mapping.Action.Arg0(rawValue: action.builtin).map { Scheme.Buttons.Mapping.Action.arg0($0).description } ?? action.builtin }
        return action.kind.label
    }
}

struct SMRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: SMRule
    let save: (SMRule) -> Void
    @State private var error: String?
    @State private var recording = false
    @State private var keyMonitor: Any?
    private var kinds: [SMTrigger.Kind] { rule.trigger.button == 1 ? [.click, .trail, .wheelUp, .wheelDown] : [.click] }
    private var actions: [SMAction.Kind] { rule.trigger.kind.compatibleActionKinds }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑手势").font(.title2.bold())
            ScrollView {
                Form {
                    TextField("名称", text: $rule.name)
                    Picker("按钮", selection: $rule.trigger.button) { ForEach([1, 2], id: \.self) { Text(smButtonName($0)).tag($0) } }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                    Picker("触发方式", selection: $rule.trigger.kind) { ForEach(kinds, id: \.self) { Text($0.label).tag($0) } }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                    if rule.trigger.kind == .trail {
                        HStack {
                            Text("轨迹")
                            Spacer(); ForEach(["U", "D", "L", "R"], id: \.self) { d in Button(smPathLabel(d)) { if rule.trigger.path.last.map(String.init) != d { rule.trigger.path += d } } }
                            Button("清空") { rule.trigger.path = "" }
                        }
                        LabeledContent("方向序列") {
                            Text(smPathLabel(rule.trigger.path))
                                .font(.title3.monospaced())
                                .frame(minWidth: 120, alignment: .trailing)
                        }
                    }
                    Divider()
                    Picker("应用范围", selection: $rule.filter.mode) { Text("所有应用").tag(SMAppFilter.Mode.all); Text("仅指定应用").tag(SMAppFilter.Mode.only); Text("排除指定应用").tag(SMAppFilter.Mode.except) }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                    if rule.filter.mode != .all {
                        ForEach(rule.filter.applications, id: \.self) { app in
                            HStack { Text(app).font(.caption); Spacer(); Button("移除") { rule.filter.applications.removeAll { $0 == app } } }
                        }
                        Button("选择应用…", action: chooseApps)
                    }
                    Divider()
                    Picker("动作", selection: $rule.action.kind) {
                        ForEach(actions, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if rule.action.kind == .shortcut {
                        LabeledContent("快捷键") {
                            HStack(spacing: 14) {
                                SMShortcutLabel(rule.action.resolvedShortcutLabel)
                                    .frame(minWidth: 120, alignment: .trailing)
                                Button(recording ? "请按快捷键…（Esc 取消）" : "录制快捷键") { startRecording() }
                                    .frame(minWidth: 132)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    if rule.action.kind == .builtin {
                        Picker("系统动作", selection: $rule.action.builtin) {
                            ForEach(Scheme.Buttons.Mapping.Action.Arg0.allCases.filter { $0 != .auto }, id: \.rawValue) { action in
                                Text(Scheme.Buttons.Mapping.Action.arg0(action).description).tag(action.rawValue)
                            }
                        }
                    }
                    if rule.action.kind == .script {
                        TextEditor(text: $rule.action.script).font(.system(.body, design: .monospaced)).frame(height: 160).border(Color.secondary.opacity(0.2))
                        Text("脚本最长运行 10 秒；访问其他应用时，macOS 会请求自动化权限。").font(.caption).foregroundStyle(.secondary)
                    }
                    if rule.trigger.kind.supportsRepeatConfiguration(for: rule.action.kind) {
                        Toggle("滚轮持续输入时重复执行", isOn: $rule.wheelRepeat)
                        if rule.wheelRepeat {
                            LabeledContent("重复间隔") {
                                Slider(value: $rule.wheelInterval, in: 0.04...2)
                                Text(String(format: "%.2f 秒", rule.wheelInterval))
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }.formStyle(.grouped)
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存") { commit() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 650, height: 650)
        .onChange(of: rule.trigger.kind) { _, _ in normalize() }
        .onChange(of: rule.trigger.button) { _, _ in
            rule.trigger.held.removeAll { $0.button == rule.trigger.button }
            if !kinds.contains(rule.trigger.kind) { rule.trigger.kind = .click }
            normalize()
        }
        .onDisappear { stopRecording() }
    }
    private func normalize() {
        if !actions.contains(rule.action.kind) {
            rule.action.kind = rule.trigger.kind.defaultActionKind
        }
    }
    private func chooseApps() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier, !rule.filter.applications.contains(id) { rule.filter.applications.append(id) } }
    }
    private func startRecording() {
        stopRecording(); recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode != 53 {
                rule.action.keyCode = event.keyCode; rule.action.modifiers = UInt64(event.modifierFlags.rawValue) & SMConfiguration.modifierMask
                rule.action.shortcutLabel = SMAction.formattedShortcutLabel(
                    keyCode: event.keyCode,
                    modifiers: rule.action.modifiers,
                    fallbackKey: event.charactersIgnoringModifiers
                )
            }
            stopRecording(); return nil
        }
    }
    private func stopRecording() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil; recording = false }
    private func commit() {
        do {
            if rule.filter.mode == .only && rule.filter.applications.isEmpty { throw SMError.invalidConfiguration }
            var config = SMConfiguration(); config.rules = [rule]; _ = try config.validated()
            save(rule); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct SMShortcutLabel: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 18, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 28, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

struct SMModifierPicker: View {
    @Binding var value: UInt64
    let title: String
    var body: some View {
        HStack {
            Text(title); Spacer()
            ForEach(Array(zip(["⌃", "⌥", "⇧", "⌘"], [CGEventFlags.maskControl, .maskAlternate, .maskShift, .maskCommand])), id: \.0) { label, flag in
                Toggle(label, isOn: Binding(get: { value & flag.rawValue != 0 }, set: { if $0 { value |= flag.rawValue } else { value &= ~flag.rawValue } })).toggleStyle(.button)
            }
        }
    }
}

struct SMActionMenu: View {
    let rule: SMRule
    let select: (SMAction) -> Void
    private var label: String {
        if rule.action.kind == .builtin {
            if rule.action.builtin == "lookUpAndDataDetectors" { return "查询与快速查看" }
            if rule.action.builtin == "smartZoom" { return "智能缩放" }
            return Scheme.Buttons.Mapping.Action.Arg0(rawValue: rule.action.builtin).map { Scheme.Buttons.Mapping.Action.arg0($0).description } ?? rule.action.builtin
        }
        return rule.action.kind == .shortcut ? rule.action.resolvedShortcutLabel : rule.action.kind.label
    }
    var body: some View {
        Menu {
            if rule.trigger.kind == .drag {
                choice(.dragScroll); choice(.dragSpaces)
            } else {
                ForEach(Scheme.Buttons.Mapping.Action.Arg0.allCases.filter { $0 != .auto }, id: \.rawValue) { builtin in
                    Button(Scheme.Buttons.Mapping.Action.arg0(builtin).description) {
                        var action = SMAction(); action.kind = .builtin; action.builtin = builtin.rawValue; select(action)
                    }
                }
                if [.wheelUp, .wheelDown].contains(rule.trigger.kind) {
                    Divider()
                    ForEach([SMAction.Kind.wheelZoom, .wheelHorizontal, .wheelQuick, .wheelPrecise, .wheelRotate, .wheelSpaces, .wheelPinch], id: \.self) { choice($0) }
                }
            }
        } label: { Text(label).frame(minWidth: 130) }
    }
    private func choice(_ kind: SMAction.Kind) -> some View {
        Button(kind.label) { var action = SMAction(); action.kind = kind; select(action) }
    }
}
