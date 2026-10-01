import SwiftUI

struct SMScrollModifiers: Codable, Equatable {
    var horizontal: UInt64 = CGEventFlags.maskShift.rawValue
    var zoom: UInt64 = CGEventFlags.maskCommand.rawValue
    var quick: UInt64 = CGEventFlags.maskControl.rawValue
    var precise: UInt64 = CGEventFlags.maskAlternate.rawValue
    func kind(for flags: UInt64) -> SMAction.Kind? {
        guard flags != 0 else { return nil }
        if flags == horizontal { return .wheelHorizontal }
        if flags == zoom { return .wheelZoom }
        if flags == quick { return .wheelQuick }
        if flags == precise { return .wheelPrecise }
        return nil
    }
}
struct SMScrollModifiersView: View {
    @ObservedObject private var state = SchemeState.shared
    private var value: SMScrollModifiers { state.mergedScheme.scrolling.sunModifiers ?? SMScrollModifiers() }
    private func binding(_ key: WritableKeyPath<SMScrollModifiers, UInt64>) -> Binding<UInt64> {
        Binding(get: { value[keyPath: key] }, set: { flags in
            var newValue = value
            // One exact modifier combination belongs to one function.
            for path in [\SMScrollModifiers.horizontal, \.zoom, \.quick, \.precise] where path != key && flags != 0 && newValue[keyPath: path] == flags { newValue[keyPath: path] = 0 }
            newValue[keyPath: key] = flags
            state.scheme.scrolling.sunModifiers = newValue
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("键盘修饰键").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("横向滚动：", key: \.horizontal)
                row("缩放：", key: \.zoom)
                row("快速滚动：", key: \.quick)
                row("精细滚动：", key: \.precise)
            }
            Button("恢复默认修饰键") { state.scheme.scrolling.sunModifiers = SMScrollModifiers() }
        }
    }

    private func row(_ title: String, key: WritableKeyPath<SMScrollModifiers, UInt64>) -> some View {
        GridRow {
            Text(title).frame(width: 78, alignment: .leading)
            SMScrollModifierCapture(value: binding(key))
        }
    }
}

/// MMF-style modifier capture field: click, hold a combination, then release.
private struct SMScrollModifierCapture: View {
    @Binding var value: UInt64
    @State private var recording = false
    @State private var pending: UInt64 = 0
    @State private var monitor: Any?
    private var label: String {
        let flags = recording ? pending : value
        let pairs: [(String, CGEventFlags)] = [("⌃", .maskControl), ("⌥", .maskAlternate), ("⇧", .maskShift), ("⌘", .maskCommand)]
        let text = pairs.filter { flags & $0.1.rawValue != 0 }.map { $0.0 }.joined()
        return text.isEmpty ? (recording ? "按下修饰键…" : "无") : text
    }
    var body: some View {
        Button { start() } label: {
            Text(label).font(.system(size: 15)).frame(width: 138, height: 20)
        }
        .help("点击后按住修饰键组合，松开保存；Delete 清除，Esc 取消。")
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(recording ? Color.accentColor : .clear, lineWidth: 2))
        .onDisappear { stop() }
    }
    private func start() {
        stop()
        recording = true
        pending = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop() }
                if [51, 117].contains(event.keyCode) { value = 0; stop() }
                return nil
            }
            let flags = UInt64(event.modifierFlags.rawValue) & SMConfiguration.modifierMask
            if flags != 0 { pending |= flags }
            else if pending != 0 { value = pending; stop() }
            return nil
        }
    }
    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
