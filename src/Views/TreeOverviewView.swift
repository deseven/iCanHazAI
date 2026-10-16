// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

extension TreeLayoutOptions {
    /// Card size and spacing of the tree overview at an interface scale (1 = 100%).
    static func overview(scale: CGFloat) -> TreeLayoutOptions {
        TreeLayoutOptions(
            nodeWidth: 220 * scale, nodeHeight: 84 * scale, siblingSpacing: 28 * scale, levelSpacing: 56 * scale)
    }
}

/// What the tree overview shows. `layout` is nil for a chat without messages.
struct TreeOverviewContent: Sendable {
    let layout: TreeLayout?
    let scale: CGFloat

    init(chat: Chat, scale: CGFloat) {
        self.scale = scale
        layout = ChatRenderQueue.buildTreeOverview(chat).map {
            TreeLayout(root: $0, options: .overview(scale: scale))
        }
    }
}

/// The conversation as a tree of its splitting points. Plain scrolling, no
/// pan/zoom: the canvas is sized to the layout.
struct TreeOverviewView: View {
    let content: TreeOverviewContent
    let roleAccent: Color
    let onSelect: (String) -> Void
    let onClose: () -> Void

    private var padding: CGFloat { 40 * content.scale }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .windowBackgroundColor)

            if let layout = content.layout {
                ScrollView([.horizontal, .vertical]) {
                    canvas(layout)
                }
            } else {
                Text("This chat has no messages yet.")
                    .font(.system(size: 14 * content.scale))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12 * content.scale, weight: .medium))
                    .frame(width: 28 * content.scale, height: 28 * content.scale)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close")
            .padding(.top, 12)
            .padding(.trailing, 16)
        }
    }

    private func canvas(_ layout: TreeLayout) -> some View {
        let size = CGSize(width: layout.width + padding * 2, height: layout.height + padding * 2)
        let accent = roleAccent
        let padding = padding
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let inactive = layout.edges.filter { !Self.isActive($0, in: layout) }
                let active = layout.edges.filter { Self.isActive($0, in: layout) }
                let lineWidth = 1.5 * content.scale
                for edge in inactive {
                    context.stroke(
                        Self.path(for: edge, in: layout, padding: padding, scale: content.scale),
                        with: .color(Color(nsColor: .separatorColor)), lineWidth: lineWidth)
                }
                for edge in active {
                    context.stroke(
                        Self.path(for: edge, in: layout, padding: padding, scale: content.scale),
                        with: .color(accent),
                        style: StrokeStyle(lineWidth: lineWidth, dash: [6 * content.scale, 5 * content.scale]))
                }
            }
            .frame(width: size.width, height: size.height)

            ForEach(layout.nodes.indices, id: \.self) { i in
                let node = layout.nodes[i]
                TreeCardView(data: node.data, scale: content.scale, accent: accent) {
                    onSelect(node.data.id)
                }
                .frame(width: layout.options.nodeWidth, height: layout.options.nodeHeight)
                .offset(x: padding + node.x, y: padding + node.y)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private static func isActive(_ edge: TreeLayout.Edge, in layout: TreeLayout) -> Bool {
        layout.nodes[edge.from].data.isActive && layout.nodes[edge.to].data.isActive
    }

    /// Rounded orthogonal path from the parent's bottom-center to the child's
    /// top-center: down to the middle of the gap, across, then down again.
    private static func path(for edge: TreeLayout.Edge, in layout: TreeLayout, padding: CGFloat, scale: CGFloat) -> Path
    {
        let from = layout.nodes[edge.from]
        let to = layout.nodes[edge.to]
        let x1 = padding + from.x + layout.options.nodeWidth / 2
        let y1 = padding + from.y + layout.options.nodeHeight
        let x2 = padding + to.x + layout.options.nodeWidth / 2
        let y2 = padding + to.y

        var path = Path()
        path.move(to: CGPoint(x: x1, y: y1))
        if abs(x2 - x1) < 0.01 {
            path.addLine(to: CGPoint(x: x2, y: y2))
            return path
        }
        let midY = (y1 + y2) / 2
        let r = min(8 * scale, abs(x2 - x1) / 2, max(0, midY - y1))
        let sx: CGFloat = x2 > x1 ? 1 : -1
        path.addLine(to: CGPoint(x: x1, y: midY - r))
        path.addQuadCurve(to: CGPoint(x: x1 + r * sx, y: midY), control: CGPoint(x: x1, y: midY))
        path.addLine(to: CGPoint(x: x2 - r * sx, y: midY))
        path.addQuadCurve(to: CGPoint(x: x2, y: midY + r), control: CGPoint(x: x2, y: midY))
        path.addLine(to: CGPoint(x: x2, y: y2))
        return path
    }
}

private struct TreeCardView: View {
    let data: TreeNodeData
    let scale: CGFloat
    let accent: Color
    let onTap: () -> Void

    @State private var hovering = false

    private var roleColor: Color {
        switch data.role {
        case "user": return .blue
        case "assistant": return accent
        case "system": return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4 * scale) {
                HStack(spacing: 6 * scale) {
                    Text(data.role.uppercased())
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .tracking(0.4 * scale)
                        .foregroundStyle(data.isActive && data.role != "user" ? accent : roleColor)
                    Spacer(minLength: 0)
                    if data.messageCount > 1 {
                        Text("\(data.messageCount) messages")
                            .font(.system(size: 10 * scale, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6 * scale)
                            .padding(.vertical, 1 * scale)
                            .background(
                                RoundedRectangle(cornerRadius: 4 * scale).fill(roleColor.opacity(0.14)))
                    }
                }
                Text(data.snippet)
                    .font(.system(size: 12 * scale))
                    .lineSpacing(1 * scale)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 8 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 8 * scale).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .stroke(
                        data.isActive ? accent.opacity(0.7) : Color(nsColor: .separatorColor),
                        lineWidth: data.isActive ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8 * scale))
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
    }
}
