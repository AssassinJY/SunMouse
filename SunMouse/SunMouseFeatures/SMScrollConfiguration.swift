import Foundation

/// Settings follow Mac Mouse Fix's ScrollTabController and ScrollConfig.
struct SMScrollConfiguration: Codable, Equatable {
    enum Smoothness: String, Codable, CaseIterable { case off, low, regular, high }
    enum Speed: String, Codable, CaseIterable { case system, low, medium, high }
    var smoothness: Smoothness = .high
    var speed: Speed = .medium
    var precise = false
    var trackpadSimulation = true

    var sendsPhases: Bool { smoothness == .high && trackpadSimulation }

    /// Runtime parameters for the finite-distance MMF-style animator.
    var smoothedConfiguration: Scheme.Scrolling.Smoothed? {
        guard smoothness != .off else { return nil }

        return runtimeConfiguration
    }

    /// Also carries the off setting: custom acceleration still applies without animation.
    var runtimeConfiguration: Scheme.Scrolling.Smoothed {
        var result = Scheme.Scrolling.Smoothed(enabled: true, bouncing: sendsPhases)
        result.mmf = self
        return result
    }
}

extension Scheme.Scrolling {
    /// Read legacy files without rewriting them. The new panel always writes the
    /// explicit MMF-style model; old curve fields no longer drive the live route.
    var resolvedSunScroll: SMScrollConfiguration {
        if let sunScroll { return sunScroll }
        var result = SMScrollConfiguration()
        if let old = smoothed.vertical {
            if !old.isEnabled { result.smoothness = .off }
            else {
                let inertia = old.inertia?.asTruncatedDouble ?? 0.74
                result.smoothness = inertia < 0.3 ? .low : inertia < 0.7 ? .regular : .high
                result.trackpadSimulation = old.allowsBouncing
                let speed = old.speed?.asTruncatedDouble ?? 1
                result.speed = speed < 0.75 ? .low : speed > 1.5 ? .high : .medium
            }
        } else if distance.vertical != nil || acceleration.vertical != nil || speed.vertical != nil {
            result.smoothness = .off
            result.speed = .system
        }
        return result
    }
}
