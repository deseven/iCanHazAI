// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// The right info panel. Shown inline next to ChatView when chatInfoSidebarVisible
/// is true. Styled to match the left ChatSidebar: a headline header bar, a
/// divider, and a .regularMaterial background.
struct ChatInfoSidebar: View {
    @EnvironmentObject var store: AppViewModel

    /// The tools available to the selected chat, fetched from the engine.
    /// Refetched whenever `toolRefreshKey` changes (role, per-chat overrides,
    /// MCP configuration, etc.).
    @State private var toolSnapshot: ChatToolSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat Info")
                    .font(.headline)
                    .padding(.leading, 12)
                Spacer()
            }
            .frame(height: 36)

            Divider()

            if let item = store.selectedChatItem {
                Form {
                    Section("Chat") {
                        InfoCell(label: "Name", value: displayName(for: item))
                    }
                    if store.selectedChatWorkdirInfoVisible {
                        Section("Working Directory") {
                            InfoCell(
                                label: "Path",
                                value: store.selectedChatWorkingDirectory.map(WorkdirItem.display) ?? "N/A",
                                tag: store.selectedChatWorkdirIsolated ? "ISOLATED" : nil
                            )
                        }
                    }
                    Section("Timestamps") {
                        InfoCell(label: "Created", value: formatted(createdDate(for: item)))
                        InfoCell(label: "Updated", value: formatted(updatedDate(for: item)))
                    }
                    Section("Usage") {
                        if let usage = item.tokenUsage, !usage.breakdownComponents.isEmpty {
                            InfoCell(label: usage.breakdownTitle, value: usage.breakdownValue)
                        } else {
                            InfoCell(label: "Tokens", value: "N/A")
                        }
                    }
                    if let snapshot = toolSnapshot {
                        if !snapshot.builtin.isEmpty {
                            Section("Tools") {
                                ForEach(
                                    groupedSections(from: snapshot.builtin, preferredOrder: BuiltinTools.groupOrder),
                                    id: \.0
                                ) { groupName, tools in
                                    ToolSubcategory(label: groupName, tools: tools) { name in
                                        store.toggleChatToolAutoApproval(toolName: name)
                                    }
                                }
                            }
                        }
                        if !snapshot.external.isEmpty {
                            Section("MCP Tools") {
                                ForEach(groupedSections(from: snapshot.external), id: \.0) { mcpName, tools in
                                    ToolSubcategory(label: mcpName, tools: tools) { name in
                                        store.toggleChatToolAutoApproval(toolName: name)
                                    }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .task(id: toolRefreshKey(for: item)) {
                    toolSnapshot = await store.chatToolSnapshot()
                }
            } else {
                Spacer()
                Text("No chat selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    /// Groups tool entries by their `source` field (built-in group name or
    /// MCP server name) and returns (groupName, tools) pairs. When
    /// `preferredOrder` is given, groups are sorted by that order (unknown
    /// groups fall back to alphabetical); otherwise purely alphabetical.
    private func groupedSections(from tools: [ChatToolEntry], preferredOrder: [String] = []) -> [(
        String, [ChatToolEntry]
    )] {
        let groups = Dictionary(grouping: tools, by: { $0.source })
        return
            groups
            .map { ($0.key, $0.value) }
            .sorted { a, b in
                let ai = preferredOrder.firstIndex(of: a.0) ?? Int.max
                let bi = preferredOrder.firstIndex(of: b.0) ?? Int.max
                if ai != bi { return ai < bi }
                return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
            }
    }

    /// Everything that can change the tool list or its approval states: the
    /// chat itself, its role, its per-chat MCP selection and approval
    /// overrides, the role definitions (a role edit may change defaults), the
    /// MCP configs, and the MCP configuration pass counter (tools coming and
    /// going as servers are reconfigured).
    private func toolRefreshKey(for item: ChatRecord) -> ToolRefreshKey {
        ToolRefreshKey(
            filename: item.filename,
            role: item.chat?.role,
            chatMCPs: item.chat?.mcps ?? [],
            autoAllow: item.chat?.autoAllow ?? [],
            autoDeny: item.chat?.autoDeny ?? [],
            roles: store.roles,
            mcps: store.mcps,
            mcpConfigurationVersion: store.mcpConfigurationVersion
        )
    }

    private struct ToolRefreshKey: Hashable {
        let filename: String
        let role: String?
        let chatMCPs: [String]
        let autoAllow: [String]
        let autoDeny: [String]
        let roles: [Role]
        let mcps: [MCPServer]
        let mcpConfigurationVersion: Int
    }

    private func displayName(for item: ChatRecord) -> String {
        if let title = item.chat?.title, !title.isEmpty {
            return title
        }
        if let firstUser = item.chat?.activeMessages.first(where: { $0.role == .user }) {
            let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(60))
            }
        }
        return item.displayTitle
    }

    private func createdDate(for item: ChatRecord) -> Date {
        item.chat?.messages.first?.timestamp ?? item.createdAt
    }

    private func updatedDate(for item: ChatRecord) -> Date {
        item.chat?.mostRecentTimestamp ?? item.createdAt
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A stacked label+value cell: label on the first line, value (possibly multiline)
/// below it, optionally followed by a grey-capsule tag. Never breaks the
/// layout regardless of value length.
private struct InfoCell: View {
    let label: String
    let value: String
    var tag: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.body)
                if let tag {
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

/// A wrapping cloud of tool tags. Auto-approved tools are green, tools that
/// require user confirmation are gray (yellow for shell with a whitelist);
/// clicking a tag flips its state.
private struct ToolTagCloud: View {
    let tools: [ChatToolEntry]
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tools, id: \.name) { tool in
                ToolTag(tool: tool) { onToggle(tool.name) }
            }
        }
        .padding(.vertical, 2)
    }
}
/// A labeled subcategory of tool tags: a small caption header (e.g.
/// "Filesystem") followed by a wrapping tag cloud. Used inside the merged
/// "Tools" and "MCP Tools" sections.
private struct ToolSubcategory: View {
    let label: String
    let tools: [ChatToolEntry]
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ToolTagCloud(tools: tools, onToggle: onToggle)
        }
    }
}

/// A single tool tag: a capsule with the tool name, tinted by approval state.
/// Hovering shows the tool's description as a tooltip.
private struct ToolTag: View {
    let tool: ChatToolEntry
    let action: () -> Void

    /// Tool descriptions can be huge; the tooltip shows only the first 300
    /// characters, terminated by an ellipsis when cut.
    private var tooltip: String {
        tool.description.count <= 300 ? tool.description : String(tool.description.prefix(300)) + "..."
    }

    private var unapprovedColor: Color {
        tool.hasShellWhitelist ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.15)
    }

    private var unapprovedBorder: Color {
        tool.hasShellWhitelist ? Color.yellow.opacity(0.5) : Color.gray.opacity(0.4)
    }

    var body: some View {
        Button(action: action) {
            Text(tool.name)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(tool.autoApproved ? Color.green.opacity(0.25) : unapprovedColor)
                )
                .overlay(
                    Capsule().strokeBorder(tool.autoApproved ? Color.green.opacity(0.6) : unapprovedBorder)
                )
        }
        .buttonStyle(.plain)
        .help(tool.description.isEmpty ? tool.name : tooltip)
    }
}

/// A minimal left-aligned flow layout: subviews are placed row by row,
/// wrapping to the next row when they exceed the available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var point = CGPoint.zero
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > 0, point.x + size.width > width {
                point.x = 0
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxWidth = max(maxWidth, point.x - spacing)
        }
        return CGSize(width: maxWidth, height: point.y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if point.x > bounds.minX, point.x + size.width > bounds.maxX {
                point.x = bounds.minX
                point.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: point, proposal: ProposedViewSize(size))
            point.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
