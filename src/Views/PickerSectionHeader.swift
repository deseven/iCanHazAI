// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A small section header used to separate pinned/default entries (built-in
/// roles, the role's default working directory) from user-managed ones in the
/// picker lists. Renders a semibold caption label over a faint tinted backdrop
/// so the pinned section reads as its own grouped area.
struct PickerSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .background(Color.secondary.opacity(0.07))
    }
}
