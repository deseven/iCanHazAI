// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

extension ProviderColor {
    /// The macOS system color. It is dynamic, so it follows the light and dark appearance.
    var nsColor: NSColor {
        switch self {
        case .blue: return .systemBlue
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .mint: return .systemMint
        case .teal: return .systemTeal
        case .cyan: return .systemCyan
        case .brown: return .systemBrown
        case .gray: return .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Black or white, whichever reads better on the color in the current appearance.
    var textColor: Color {
        let background = nsColor
        return Color(
            nsColor: NSColor(name: nil) { appearance in
                var isDark = false
                appearance.performAsCurrentDrawingAppearance {
                    let rgb = background.usingColorSpace(.sRGB) ?? background
                    let brightness = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                    isDark = brightness < 0.5
                }
                return isDark ? .white : .black
            })
    }
}

extension Provider {
    /// Brand color of the provider's tag background. A custom provider's is
    /// the user's pick (see `ProviderTag.color`); this is its fallback.
    var brandColor: Color {
        switch self {
        case .openrouter: return Color(red: 0xC8 / 255, green: 0xFF / 255, blue: 0x00 / 255)
        case .openai: return .white
        case .deepseek: return Color(red: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255)
        case .anthropic: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .custom: return ProviderColor.default.color
        }
    }

    /// Readable text color on top of `brandColor`.
    var brandTextColor: Color {
        switch self {
        case .openrouter, .openai: return .black
        case .deepseek, .anthropic: return .white
        case .custom: return ProviderColor.default.textColor
        }
    }
}

/// A small provider-colored capsule shown before a model name.
struct ProviderTag: View {
    let provider: Provider
    /// The color of a custom provider; built-in providers keep their brand color.
    var color: ProviderColor?

    var body: some View {
        Text(provider.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var background: Color {
        provider.isCustom ? (color ?? .default).color : provider.brandColor
    }

    private var foreground: Color {
        provider.isCustom ? (color ?? .default).textColor : provider.brandTextColor
    }
}
