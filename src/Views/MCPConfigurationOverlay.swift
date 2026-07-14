// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The shared loader card: one or two titled columns ("Application" / "MCPs"),
/// each a list of label + status-icon rows. Purely a projection of
/// `LoaderController`; owns no logic. Used both by the startup window (with a
/// title) and the usage overlay (without).
///
/// Columns have a fixed width so the card is content-sized (not stretched to
/// fill its container); the host (window / overlay) centers it.
struct LoaderCard: View {
    @ObservedObject private var loader = LoaderController.shared
    let title: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            HStack(alignment: .top, spacing: 28) {
                ForEach(loader.sections) { section in
                    column(section)
                }
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 12)
        .fixedSize()
    }

    private func column(_ section: LoaderSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(section.entries) { entry in
                row(entry)
            }
        }
        .frame(width: 225, alignment: .leading)
    }

    /// Every row carries a stable subtitle (entry count / "pending" / tool
    /// count / error), rendered as a caption under the label. The caption is
    /// always reserved so row heights stay constant as statuses change.
    private func row(_ entry: LoaderEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(entry.detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(entry.detail == nil ? 0 : 1)
            }
            Spacer(minLength: 8)
            statusIcon(entry.status)
                .frame(width: 20, height: 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusIcon(_ status: LoaderStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

/// The usage-mode overlay on the main window. Shown only when the loader is
/// visible in `.usage` mode — i.e. an external change is being applied. Renders
/// only the affected columns/entries, then fades out 1 second after everything
/// settles.
struct LoaderOverlay: View {
    @ObservedObject private var loader = LoaderController.shared

    private var show: Bool { loader.visible && loader.mode == .usage }

    var body: some View {
        Group {
            if show {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                    LoaderCard(title: nil)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: show)
    }
}

/// The content hosted in the startup loader window. Renders the full card
/// (both columns); the window's `alphaValue` handles the fade-out, so this view
/// always shows its current sections.
///
/// The surrounding padding gives the card's rounded drop shadow room to render
/// inside the (transparent, borderless) window — without it the shadow is
/// clipped to the window's straight bounds, producing a rectangular halo that
/// fights the card's rounded corners.
struct LoaderStartView: View {
    var body: some View {
        LoaderCard(title: "iCanHazAI starting up…")
            .padding(24)
    }
}
