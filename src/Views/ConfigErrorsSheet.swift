// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The sheet shown when the user presses the title-bar configuration-errors
/// button. Lists every current [`ConfigError`](src/Chat/Models.swift) and offers two
/// actions: dismiss ("Acknowledged") or open a new Configurator chat pre-filled
/// with the errors ("Fix with Configurator").
struct ConfigErrorsSheet: View {
    let errors: [ConfigError]
    let onAcknowledge: () -> Void
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configuration problems")
                .font(.headline)

            Text(verbatim: "The failed entities have been disabled. You can fix them manually in Finder, or let the Configurator propose solutions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(errors) { error in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(error.kindLabel): \(error.entityName)")
                                    .font(.callout.bold())
                                Text(verbatim: error.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Spacer()
                Button("Acknowledged", action: onAcknowledge)
                    .keyboardShortcut(.cancelAction)
                Button("Fix with Configurator", action: onFix)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }
}
