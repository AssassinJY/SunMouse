import SwiftUI

struct ScrollingSettings: View {
    @ObservedObject private var state = ScrollingSettingsState.shared
    @ObservedObject private var schemes = SchemeState.shared
    private var configuration: SMScrollConfiguration { schemes.mergedScheme.scrolling.resolvedSunScroll }

    private func binding<T>(_ key: WritableKeyPath<SMScrollConfiguration, T>) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] }, set: {
            var value = configuration
            value[keyPath: key] = $0
            schemes.scheme.scrolling.sunScroll = value
        })
    }

    var body: some View {
        DetailView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("反转滚动方向", isOn: Binding(get: {
                        schemes.mergedScheme.scrolling.reverse.vertical ?? false
                    }, set: { value in
                        schemes.scheme.scrolling.reverse = .init(vertical: value, horizontal: value)
                    }))
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("平滑滚动：").frame(width: 78, alignment: .leading)
                            Picker("平滑滚动", selection: binding(\.smoothness)) {
                                Text("关闭").tag(SMScrollConfiguration.Smoothness.off)
                                // MMF hides its experimental low option in release builds.
                                if configuration.smoothness == .low {
                                    Text("低（实验性）").tag(SMScrollConfiguration.Smoothness.low)
                                }
                                Text("常规").tag(SMScrollConfiguration.Smoothness.regular)
                                Text("高").tag(SMScrollConfiguration.Smoothness.high)
                            }.labelsHidden().frame(width: 162, alignment: .leading)
                        }
                        if configuration.smoothness == .high {
                            GridRow {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                VStack(alignment: .leading, spacing: 5) {
                                    Toggle("模拟触控板", isOn: binding(\.trackpadSimulation))
                                    hint("启用边缘回弹和横向滑动导航。")
                                }
                            }
                        }
                        GridRow {
                            Text("滚动速度：")
                            Picker("滚动速度", selection: binding(\.speed)) {
                                Text("系统").tag(SMScrollConfiguration.Speed.system)
                                Text("低").tag(SMScrollConfiguration.Speed.low)
                                Text("中").tag(SMScrollConfiguration.Speed.medium)
                                Text("高").tag(SMScrollConfiguration.Speed.high)
                            }.labelsHidden().frame(width: 162, alignment: .leading)
                        }
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            if configuration.speed != .system {
                                VStack(alignment: .leading, spacing: 5) {
                                    Toggle("精细滚动", isOn: binding(\.precise))
                                    hint("缓慢转动时移动更小的距离，快速转动时仍可快速浏览。\n也可以按住下面设置的修饰键，临时精细滚动。")
                                }
                            } else {
                                hint("滚动速度由 macOS 的鼠标设置决定。")
                            }
                        }
                    }
                    Divider()
                    SMScrollModifiersView()
                    if state.showsHighResolutionWheelControl {
                        LogitechHighResolutionWheelSection()
                    }
                    Button("恢复默认滚动设置") {
                        schemes.scheme.scrolling.sunScroll = SMScrollConfiguration()
                        schemes.scheme.scrolling.reverse = .init(vertical: true, horizontal: true)
                        schemes.scheme.scrolling.sunModifiers = SMScrollModifiers()
                    }
                }
                .toggleStyle(.checkbox)
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.onAppear { state.refreshHighResolutionWheelInfo() }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
