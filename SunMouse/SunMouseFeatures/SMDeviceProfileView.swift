import SwiftUI
struct SMDeviceProfileView: View {
    @ObservedObject private var devices = DeviceState.shared
    @ObservedObject private var schemes = SchemeState.shared
    @State private var copied = false
    var body: some View {
        if let device = devices.currentDeviceRef?.value {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text(device.pointerDevice.transport ?? "标准鼠标").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu("复制已有设备配置") {
                        ForEach(Array(schemes.schemes.enumerated()), id: \.offset) { _, source in
                            if let matcher = source.if?.first?.device, let name = matcher.productName {
                                Button(name + (matcher.locationID.map { " · 连接 \($0)" } ?? "")) {
                                    var destination = schemes.scheme
                                    destination.$pointer = source.$pointer; destination.$scrolling = source.$scrolling
                                    schemes.scheme = destination; copied = true
                                }
                            }
                        }
                    }
                }
                if device.serialNumber?.isEmpty != false {
                    Text("设备未提供序列号，配置按设备型号与连接位置匹配。更换接口后可复制已有配置；接收器未区分的鼠标可能共用配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if copied { Text("已复制到当前设备。").font(.caption).foregroundStyle(.secondary) }
            }.modifier(SectionViewModifier())
        }
    }
}
