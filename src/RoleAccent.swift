// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// Resolves a role's `accent` TOML alias to a color. Aliases map to adaptive
/// `NSColor.system*` colors so they adapt to light/dark mode. An absent or
/// unrecognized alias falls back to the macOS accent color (system setting).
enum RoleAccent {
    /// Human-readable alias → adaptive system color. Lowercased on lookup.
    private static let aliases: [String: NSColor] = [
        "red": .systemRed,
        "orange": .systemOrange,
        "yellow": .systemYellow,
        "green": .systemGreen,
        "blue": .systemBlue,
        "purple": .systemPurple,
        "pink": .systemPink,
        "teal": .systemTeal,
        "indigo": .systemIndigo,
        "mint": .systemMint,
        "cyan": .systemCyan,
        "brown": .systemBrown,
        "gray": .systemGray,
        "grey": .systemGray,
    ]

    /// The supported alias names, lowercased. Exposed for validation/UI.
    static let supportedAliases: [String] = [
        "red", "orange", "yellow", "green", "blue", "purple", "pink",
        "teal", "indigo", "mint", "cyan", "brown", "gray",
    ]

    /// Returns the adaptive system color for an alias, or nil when the alias
    /// is absent/unrecognized (caller falls back to the system accent).
    static func nsColor(for alias: String?) -> NSColor? {
        guard let alias else { return nil }
        return aliases[alias.lowercased()]
    }

    /// Resolved SwiftUI color for an alias, falling back to `Color.accentColor`
    /// (the macOS accent color) when absent or unrecognized.
    static func color(for alias: String?) -> Color {
        if let ns = nsColor(for: alias) {
            return Color(nsColor: ns)
        }
        return Color.accentColor
    }

    /// Resolves the accent color for an alias to an "#RRGGBB" hex string,
    /// resolved against the app's current effective appearance so it matches
    /// the active light/dark theme. Falls back to the macOS control accent
    /// color when the alias is absent/unrecognized. The resolved value is
    /// appearance-dependent and must not be persisted — re-resolve on theme
    /// change.
    static func hexColor(for alias: String?) -> String {
        let nsColor = nsColor(for: alias) ?? NSColor.controlAccentColor
        var resolved = nsColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = nsColor.usingColorSpace(.sRGB) ?? nsColor
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

extension Role {
    /// Accent color for this role: the TOML `accent` alias resolved to an
    /// adaptive system color, falling back to the macOS accent color.
    var accentColor: Color { RoleAccent.color(for: config.accent) }
}
