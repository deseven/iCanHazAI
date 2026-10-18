// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

extension Provider {
    /// Brand color of the provider's tag background.
    var brandColor: Color {
        switch self {
        case .openrouter: return Color(red: 0xC8 / 255, green: 0xFF / 255, blue: 0x00 / 255)
        case .openai: return .white
        case .deepseek: return Color(red: 0x4D / 255, green: 0x6B / 255, blue: 0xFE / 255)
        case .anthropic: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        }
    }

    /// Readable text color on top of `brandColor`.
    var brandTextColor: Color {
        switch self {
        case .openrouter, .openai: return .black
        case .deepseek, .anthropic: return .white
        }
    }
}

/// A small provider-colored capsule shown before a model name.
struct ProviderTag: View {
    let provider: Provider

    var body: some View {
        Text(provider.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(provider.brandTextColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(provider.brandColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
