import AppKit

final class SMTrailOverlay {
    static let shared = SMTrailOverlay()
    private var windows: [Int32: NSWindow] = [:]
    func show(
        device: Int32,
        points: [CGPoint],
        width: Double,
        colorHex: String,
        showTrail: Bool,
        label: String?,
        labelFontSize: Double,
        labelColorHex: String,
        labelBackgroundColorHex: String,
        labelPosition: SMGestureLabelPosition
    ) {
        guard !points.isEmpty else { return }
        let bounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let window: NSWindow
        if let existing = windows[device] { window = existing }
        else {
            window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            window.contentView = SMTrailView(frame: CGRect(origin: .zero, size: bounds.size)); windows[device] = window
        }
        guard let view = window.contentView as? SMTrailView else { return }
        view.points = points.map { CGPoint(x: $0.x - bounds.minX, y: bounds.maxY - $0.y) }
        view.lineWidth = width
        view.color = NSColor(smHex: colorHex) ?? .controlAccentColor.withAlphaComponent(0.85)
        view.showsTrail = showTrail
        view.label = label
        view.labelFontSize = labelFontSize
        view.labelColor = NSColor(smHex: labelColorHex) ?? .white
        view.labelBackgroundColor = NSColor(smHex: labelBackgroundColorHex) ?? .black.withAlphaComponent(0.72)
        view.labelPosition = labelPosition
        view.needsDisplay = true; window.orderFrontRegardless()
    }
    func hide(device: Int32) { windows.removeValue(forKey: device)?.orderOut(nil) }
}
private final class SMTrailView: NSView {
    var points: [CGPoint] = []
    var lineWidth = 4.0
    var color = NSColor.controlAccentColor.withAlphaComponent(0.85)
    var showsTrail = true
    var label: String?
    var labelFontSize = 24.0
    var labelColor = NSColor.white
    var labelBackgroundColor = NSColor.black.withAlphaComponent(0.72)
    var labelPosition = SMGestureLabelPosition.center
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        guard let first = points.first else { return }
        if showsTrail {
            let path = NSBezierPath(); path.lineWidth = lineWidth; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: first); for point in points.dropFirst() { path.line(to: point) }
            color.setStroke(); path.stroke()
        }
        drawLabel()
    }
    private func drawLabel() {
        guard let label, !label.isEmpty, let endpoint = points.last else { return }
        let font = NSFont.systemFont(ofSize: labelFontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: labelColor]
        let textSize = label.size(withAttributes: attributes)
        let horizontalPadding = max(10, labelFontSize * 0.45)
        let verticalPadding = max(6, labelFontSize * 0.28)
        let size = CGSize(
            width: min(textSize.width + horizontalPadding * 2, max(80, bounds.width - 24)),
            height: textSize.height + verticalPadding * 2
        )
        let screenRect = screenRect(containing: endpoint)
        let origin = labelOrigin(size: size, in: screenRect)
        let backgroundRect = CGRect(origin: origin, size: size)
        labelBackgroundColor.setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: 8, yRadius: 8).fill()
        let textRect = backgroundRect.insetBy(dx: horizontalPadding, dy: verticalPadding)
        label.draw(in: textRect, withAttributes: attributes)
    }

    private func labelOrigin(size: CGSize, in screenRect: CGRect) -> CGPoint {
        // MacGesture uses a 32 pt screen inset plus the label's 10 pt padding.
        let edgeInset = 42.0
        let menuBarInset = 25.0
        let left = screenRect.minX + edgeInset
        let centerX = screenRect.midX - size.width / 2
        let right = screenRect.maxX - size.width - edgeInset
        let bottom = screenRect.minY + edgeInset
        let centerY = screenRect.midY - size.height / 2
        let top = screenRect.maxY - size.height - edgeInset - menuBarInset

        switch labelPosition {
        case .center: return CGPoint(x: centerX, y: centerY)
        case .topLeft: return CGPoint(x: left, y: top)
        case .topCenter: return CGPoint(x: centerX, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomCenter: return CGPoint(x: centerX, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }

    private func screenRect(containing point: CGPoint) -> CGRect {
        let desktopBounds = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let screenRects = NSScreen.screens.map { screen in
            CGRect(
                x: screen.frame.minX - desktopBounds.minX,
                y: screen.frame.minY - desktopBounds.minY,
                width: screen.frame.width,
                height: screen.frame.height
            )
        }
        return screenRects.first(where: { $0.contains(point) }) ?? bounds
    }
}

extension NSColor {
    convenience init?(smHex: String) {
        guard smHex.count == 8, let value = UInt64(smHex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 24) & 0xff) / 255,
            green: CGFloat((value >> 16) & 0xff) / 255,
            blue: CGFloat((value >> 8) & 0xff) / 255,
            alpha: CGFloat(value & 0xff) / 255
        )
    }

    var smHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "%02X%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()),
            Int((color.alphaComponent * 255).rounded())
        )
    }
}
