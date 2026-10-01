// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation

extension CGEvent {
    /// Creates a key event that is indistinguishable from a hardware key press.
    ///
    /// Events created without a source carry no HID system state, a zero timestamp and no keyboard type.
    /// Some event consumers (e.g. Wine's mouse-capture and modifier tracking in games) treat such events
    /// as foreign and mistrack input state around them. The keyboard type is read from the event source
    /// rather than `LMGetKbdType()`, which is not thread-safe and would race with `KeyCodeResolver`.
    static func makeHardwareLikeKeyEvent(virtualKey: CGKeyCode, keyDown: Bool) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
            return nil
        }

        event.timestamp = CGEventTimestamp(DispatchTime.now().uptimeNanoseconds)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: Int64(source.keyboardType))
        return event
    }
}
