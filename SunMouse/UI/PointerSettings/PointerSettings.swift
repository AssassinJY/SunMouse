// MIT License
// Copyright (c) 2021-2026 LinearMouse

import SwiftUI

struct PointerSettings: View {
    @ObservedObject var state = PointerSettingsState.shared
    @State private var isPointerSpeedLimitationPopoverPresented = false

    var body: some View {
        DetailView {
            Form {
                    SMDeviceProfileView()
                Section {
                    if !state.pointerDisableAcceleration {
                        HStack(alignment: .firstTextBaseline) {
                            Slider(
                                value: pointerAccelerationSliderValue,
                                in: 0.0 ... 100.0
                            ) {
                                labelWithDescription {
                                    Text("Pointer acceleration")
                                    Text(verbatim: "(0–100%)")
                                }
                            }
                            TextField(
                                String(""),
                                value: $state.pointerAccelerationPercentage,
                                formatter: state.pointerPercentageFormatter
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        }

                        HStack(alignment: .firstTextBaseline) {
                            Slider(
                                value: pointerSpeedSliderValue,
                                in: 0.0 ... 100.0
                            ) {
                                labelWithDescription {
                                    HStack(spacing: 4) {
                                        Text("Pointer speed")

                                        if state.showsPointerSpeedLimitationNotice {
                                            Button {
                                                isPointerSpeedLimitationPopoverPresented.toggle()
                                            } label: {
                                                Text(verbatim: "⚠︎")
                                                    .foregroundColor(.orange)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .popover(
                                                isPresented: $isPointerSpeedLimitationPopoverPresented,
                                                arrowEdge: .top
                                            ) {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    Text(
                                                        "Due to system limitations, this device may not support adjusting Pointer Speed on newer versions of macOS."
                                                    )
                                                    .fixedSize(horizontal: false, vertical: true)

                                                    HyperLink(
                                                        URL(
                                                            string: "https://go.linearmouse.app/pointer-speed-limitations"
                                                        )!
                                                    ) {
                                                        Text("Learn more")
                                                    }
                                                }
                                                .padding()
                                                .frame(width: 280, alignment: .leading)
                                            }
                                        }
                                    }

                                    Text(verbatim: "(0–100%)")
                                }
                            }
                            TextField(
                                String(""),
                                value: $state.pointerSpeedPercentage,
                                formatter: state.pointerPercentageFormatter
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        }

                        if state.showsPointerHardwareDPIControl {
                            pointerHardwareDPIControl
                        }

                        if #available(macOS 11.0, *) {
                            Button("Revert to system defaults") {
                                revertPointerSpeed()
                            }
                            .keyboardShortcut("z", modifiers: [.control, .command, .shift])

                            Text("You may also press ⌃⇧⌘Z to revert to system defaults.")
                                .settingsDescriptionStyle()
                        } else {
                            Button("Revert to system defaults") {
                                revertPointerSpeed()
                            }
                        }
                    } else if #available(macOS 14, *) {
                        HStack(alignment: .firstTextBaseline) {
                            Slider(
                                value: pointerAccelerationSliderValue,
                                in: 0.0 ... 100.0
                            ) {
                                labelWithDescription {
                                    Text("Tracking speed")
                                    Text(verbatim: "(0–100%)")
                                }
                            }
                            TextField(
                                String(""),
                                value: $state.pointerAccelerationPercentage,
                                formatter: state.pointerPercentageFormatter
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        }

                        if state.showsPointerHardwareDPIControl {
                            pointerHardwareDPIControl
                        }

                        Button("Revert to system defaults") {
                            revertPointerSpeed()
                        }
                        .keyboardShortcut("z", modifiers: [.control, .command, .shift])

                        Text("You may also press ⌃⇧⌘Z to revert to system defaults.")
                            .settingsDescriptionStyle()
                    } else {
                        if state.showsPointerHardwareDPIControl {
                            pointerHardwareDPIControl
                        }
                    }
                }
                .modifier(SectionViewModifier())
            }
            .modifier(FormViewModifier())
        }
        .onAppear {
            state.refreshPointerHardwareDPIInfo()
        }
    }

    private func revertPointerSpeed() {
        state.revertPointerSpeed()
    }

    private var pointerAccelerationSliderValue: Binding<Double> {
        Binding(
            get: { state.pointerAccelerationPercentage },
            set: { state.pointerAccelerationPercentage = $0.rounded() }
        )
    }

    private var pointerSpeedSliderValue: Binding<Double> {
        Binding(
            get: { state.pointerSpeedPercentage },
            set: { state.pointerSpeedPercentage = $0.rounded() }
        )
    }

    private var pointerHardwareDPIControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let info = state.pointerHardwareDPIInfo,
               info.currentDPI != nil,
               let range = info.dpiRange {
                pointerHardwareDPISetter(range: range)

                if let message = state.pointerHardwareDPIStatusMessage {
                    Text(message)
                        .foregroundColor(.secondary)
                }
            } else if state.pointerHardwareDPIBusy {
                Text(state.pointerHardwareDPIApplying ? "Applying..." : "Refreshing...")
                    .foregroundColor(.secondary)
            } else {
                Text(state.pointerHardwareDPIStatusMessage ?? "Reading hardware DPI from the selected device.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func pointerHardwareDPISetter(range: ClosedRange<Int>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if range.lowerBound < range.upperBound {
                Slider(
                    value: Binding(
                        get: { Double(state.pointerHardwareDPITargetDPI) },
                        set: { state.updatePointerHardwareDPITargetDPI(Int($0.rounded())) }
                    ),
                    in: Double(range.lowerBound) ... Double(range.upperBound)
                ) {
                    labelWithDescription {
                        Text("Hardware DPI")
                        Text(verbatim: "(\(range.lowerBound)–\(range.upperBound))")
                    }
                }
            } else {
                labelWithDescription {
                    Text("Hardware DPI")
                    Text(verbatim: "(\(range.lowerBound))")
                }
                Spacer()
            }

            DeferredNumberField(
                value: Binding(
                    get: { Double(state.pointerHardwareDPITargetDPI) },
                    set: { state.commitPointerHardwareDPITargetDPI(Int($0.rounded())) }
                ),
                formatter: state.pointerDPIFormatter,
                range: Double(range.lowerBound) ... Double(range.upperBound)
            )
            .frame(width: 80)
            .accessibility(label: Text("Hardware DPI"))
        }
    }
}
