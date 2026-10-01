import SwiftUI
import LaunchAtLogin
struct SMGeneralView: View {
    @ObservedObject private var store = SMRuleStore.shared
    var body: some View {
        Form {
            Section("SunMouse") {
                Text("管理指针、滚轮、侧键与手势。").foregroundStyle(.secondary)
                LabeledContent("版本", value: SunMouse.appVersion)
                if CommandLine.arguments.contains("--preview") { Text("预览模式：尚未启动鼠标事件处理。").foregroundStyle(.secondary) }
                LabeledContent("辅助功能", value: AccessibilityPermission.enabled ? "已授权" : "等待授权")
                if !AccessibilityPermission.enabled { Button("打开辅助功能设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) } }
                LaunchAtLogin.Toggle("登录时启动")
                Button(store.paused ? "恢复 SunMouse" : "暂停 SunMouse") { toggleSMPause() }.disabled(CommandLine.arguments.contains("--preview"))
            }
            Section("配置") {
                HStack { Button("导出全部配置…") { store.exportConfiguration() }; Button("导入配置…") { store.importConfiguration() } }
                Text("导入前保留一份备份。配置仅保存在本机。").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.lastError { Section("最近错误") { Text(error).foregroundStyle(.red).textSelection(.enabled); Button("清除") { store.lastError = nil } } }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
func toggleSMPause() {
    let store = SMRuleStore.shared
    store.paused.toggle()
    guard let delegate = NSApp.delegate as? AppDelegate else { return }
    if store.paused { delegate.stop() } else if AccessibilityPermission.enabled { delegate.startIfAllowed() }
}
