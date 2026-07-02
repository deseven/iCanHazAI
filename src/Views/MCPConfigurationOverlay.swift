// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// A half-transparent overlay shown over the main UI while MCP servers are
/// being configured. Displays each server's name and its current status
/// (pending / in-progress spinner / success / failure icon). Stays visible
/// for 1 second after configuration completes so the user can evaluate the
/// results, then fades out.
///
/// The overlay is purely a UI projection of `AppViewModel.mcpConfiguration`;
/// it owns no business logic. It is shown only when there is at least one
/// entry and either a configuration pass is in progress or the 1-second
/// display delay hasn't elapsed yet.
struct MCPConfigurationOverlay: View {
    @EnvironmentObject private var store: AppViewModel

    /// Whether the overlay should currently be visible. True while
    /// `isConfiguring` is true, and for 1 second after it flips to false (so
    /// the user can see the final results).
    @State private var visible = false
    /// Task that hides the overlay 1 second after configuration completes.
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible {
                content
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visible)
        .onChange(of: store.mcpConfiguration) { _, newState in
            handle(newState)
        }
        .onAppear {
            handle(store.mcpConfiguration)
        }
    }

    /// The overlay content: a dimmed background and a centered card listing
    /// each server's status.
    private var content: some View {
        ZStack {
            // Half-transparent dimming layer over the whole window.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
            // Centered status card.
            VStack(alignment: .leading, spacing: 10) {
                Text("Configuring MCP servers")
                    .font(.headline)
                    .foregroundStyle(.primary)
                ForEach(store.mcpConfiguration.entries) { entry in
                    row(for: entry)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
            .frame(maxWidth: 360)
        }
    }

    /// One status row: server name (left) and status icon (right).
    @ViewBuilder
    private func row(for entry: MCPConfigurationEntry) -> some View {
        HStack(spacing: 16) {
            Text(entry.name)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            statusIcon(for: entry)
                .frame(width: 20, height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The SF Symbol / spinner for a given status.
    @ViewBuilder
    private func statusIcon(for entry: MCPConfigurationEntry) -> some View {
        switch entry.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    /// Decides overlay visibility based on the configuration state. Shows the
    /// overlay while configuring (and when there are entries), and schedules
    /// a 1-second hide after configuration completes.
    private func handle(_ state: MCPConfigurationState) {
        let hasEntries = !state.entries.isEmpty
        if state.isConfiguring && hasEntries {
            // Still in progress: ensure visible, cancel any pending hide.
            hideTask?.cancel()
            hideTask = nil
            visible = true
        } else if hasEntries {
            // Just finished: keep visible for 1 second so the user can read
            // the results, then hide.
            hideTask?.cancel()
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                visible = false
            }
        } else {
            // No entries (no MCPs configured): hide immediately.
            hideTask?.cancel()
            hideTask = nil
            visible = false
        }
    }
}
