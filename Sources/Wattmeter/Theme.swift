import SwiftUI

/// Single source of truth for app colors. Inspired by Linear's "base + accent + contrast" approach.
/// Warm-neutral foundation (Pampas/Cloudy) + Claude's signature Crail coral as the only chromatic accent.
/// Semantic red/orange/green are reserved exclusively for live limit signals.
enum Theme {
    /// Claude brand: Crail #C15F3C. The sole non-neutral accent in the UI.
    static let accent = Color(red: 0xC1/255.0, green: 0x5F/255.0, blue: 0x3C/255.0)
    /// Softer accent for fills/gradients.
    static let accentSoft = Color(red: 0xD9/255.0, green: 0x77/255.0, blue: 0x57/255.0)

    /// Semantic — limit states only.
    static let ok = Color.green
    static let warn = Color.orange
    static let danger = Color.red

    /// Heatmap ramp: monochromatic accent.
    static func heat(_ t: Double) -> Color {
        accent.opacity(0.08 + 0.82 * max(0, min(1, t)))
    }
}
