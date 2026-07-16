// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

/// One of the application-level resources the loader reports progress for.
/// Each maps to a directory (or the root config) that the engine reloads.
enum AppResource: String, Sendable, CaseIterable {
    case configuration
    case chats
    case connections
    case prompts
    case roles

    var id: String { rawValue }
    var title: String {
        switch self {
        case .configuration: return "Configuration"
        case .chats: return "Chats"
        case .connections: return "Connections"
        case .prompts: return "Prompts"
        case .roles: return "Roles"
        }
    }
}

/// The status of a single loader line. Mirrors `MCPConfigStatus` plus a
/// `warning` state used by Application lines that pile multiple files under a
/// single label when some — but not all — of the files failed to load.
enum LoaderStatus: Sendable, Equatable {
    case pending
    case inProgress
    case success
    case warning
    case failed

    init(_ status: MCPConfigStatus) {
        switch status {
        case .pending: self = .pending
        case .inProgress: self = .inProgress
        case .success: self = .success
        case .failed: self = .failed
        }
    }
}

/// One row in the loader: a label (e.g. "Connections") plus a `detail`
/// subtitle (e.g. "3 entries") and its status.
///
/// - `total`: the number of items of this kind on disk (drives the
///   success/warning/failed derivation by comparing against how many decoded).
/// - `refreshCount`: the number of items actually being refreshed in this pass
///   (drives the subtitle). During startup / a full rescan this equals `total`
///   (everything reloads); for a single-file external edit it's 1.
struct LoaderEntry: Identifiable, Equatable {
    let id: String
    var label: String
    var status: LoaderStatus
    var detail: String?
    var total: Int
    var refreshCount: Int
}

/// "1 entry" / "2 entries" / "0 tools" — English pluralization for the
/// loader subtitles.
func loaderPluralized(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(plural)"
}

/// A titled column in the loader ("Application" / "MCPs") with its rows.
struct LoaderSection: Identifiable, Equatable {
    let id: String
    let title: String
    var entries: [LoaderEntry]
}

/// Engine-to-UI loader activity signal. The MCP column is driven separately by
/// the existing `.mcpConfiguration` event; this carries only Application-side
/// activity (a batch of resource reloads that just started).
struct LoaderActivity: Sendable, Equatable {
    /// Each affected resource mapped to the total number of items of that kind
    /// currently on disk (drives the success/warning/failed derivation).
    let counts: [AppResource: Int]
    /// Each affected resource mapped to the number of items being refreshed in
    /// this batch (drives the subtitle). When omitted for a resource, `counts`
    /// is used — i.e. the whole resource is being reloaded (startup / rescan).
    let refreshCounts: [AppResource: Int]

    init(counts: [AppResource: Int], refreshCounts: [AppResource: Int] = [:]) {
        self.counts = counts
        self.refreshCounts = refreshCounts
    }
}

/// The single source of truth for the loader UI. Aggregates two columns
/// (Application + MCPs) and manages visibility / the 1-second display delay.
///
/// Two modes:
/// - `.startup`: a separate borderless floating window shows both columns while
///   the app boots. Seeded synchronously from `AppDelegate` right after the
///   main config is read, then completed as the engine emits load events.
/// - `.usage`: an overlay on the main window shows only the parts affected by
///   an external change (a single column / a subset of entries).
@MainActor
final class LoaderController: ObservableObject {

    static let shared = LoaderController()

    enum Mode: Equatable { case idle, startup, usage }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var sections: [LoaderSection] = []
    @Published private(set) var visible: Bool = false

    /// Notified on every visibility transition (true → shown, false → hidden).
    /// Set by the startup window controller so it can show / fade out without
    /// polling. Runs on the main actor.
    var visibilityHandler: ((Bool) -> Void)?

    /// Fired exactly once per `.startup` pass, at the moment every entry has
    /// settled and the 1-second results-display delay has just begun. The app
    /// wires this to create and show the main window (which doesn't exist
    /// during boot) and surface any configuration errors collected during
    /// startup.
    var startupReadyHandler: (() -> Void)?

    private var hideTask: Task<Void, Never>?
    /// Guards `startupReadyHandler` against firing more than once per startup.
    private var startupReadyFired = false

    private init() {}

    private func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        visibilityHandler?(value)
    }

    // MARK: - Startup

    /// Seeds both columns from the on-disk environment and shows the loader.
    /// Called once from `AppDelegate` right after the main config is read, so
    /// the list of "what we'll need to load" is known up front. Configuration
    /// is already loaded at this point, so it's marked complete immediately.
    func beginStartup() {
        hideTask?.cancel()
        hideTask = nil
        startupReadyFired = false
        mode = .startup
        let env = EnvironmentManager.shared
        let counts: [AppResource: Int] = [
            .configuration: 1,
            .chats: env.chatCount(),
            .connections: env.connectionCount(),
            .prompts: env.promptCount(),
            .roles: env.roleCount(),
        ]
        let appEntries: [LoaderEntry] = AppResource.allCases.map { r in
            let n = counts[r] ?? 0
            // Startup reloads everything, so the refresh count equals the total.
            return LoaderEntry(
                id: r.id,
                label: r.title,
                status: r == .configuration ? .success : .pending,
                detail: resourceSubtitle(r, count: n),
                total: n,
                refreshCount: n
            )
        }
        let mcps = MCPManager.builtinServers() + env.loadMCPs().sorted { $0.name < $1.name }
        // MCP rows show "pending" as their subtitle immediately; the tool count
        // replaces it once the server reports back.
        let mcpEntries = mcps.map {
            LoaderEntry(id: $0.name, label: $0.name, status: .pending, detail: "pending", total: 1, refreshCount: 1)
        }
        sections = [
            LoaderSection(id: "application", title: "Application", entries: appEntries),
            LoaderSection(id: "mcps", title: "MCPs", entries: mcpEntries),
        ]
        setVisible(true)
        reevaluate()
    }

    // MARK: - Usage: Application batch started

    /// A batch of external Application-resource reloads just started (FSEvents
    /// debounce flushed). Shows a single "Application" column with an
    /// in-progress entry per affected resource. Ignored during startup (which
    /// drives its own entries). Keeps any existing MCPs column in place so a
    /// mixed burst can show both.
    func applicationStarted(_ counts: [AppResource: Int], refreshCounts: [AppResource: Int] = [:]) {
        guard mode != .startup else { return }
        guard !counts.isEmpty else { return }
        hideTask?.cancel()
        hideTask = nil
        // A new usage pass starts from a clean slate so a stale column from a
        // previous pass (e.g. a leftover "Application" column from startup)
        // doesn't bleed into this one.
        if mode == .idle {
            mode = .usage
            sections = []
        }
        let appEntries: [LoaderEntry] = AppResource.allCases.compactMap { r in
            guard let n = counts[r] else { return nil }
            // The subtitle reflects how many items are being refreshed in this
            // batch (e.g. "1 entry" for a single-file edit); `total` keeps the
            // on-disk count for the success/warning/failed derivation.
            let refresh = refreshCounts[r] ?? n
            return LoaderEntry(id: r.id, label: r.title, status: .inProgress, detail: resourceSubtitle(r, count: refresh), total: n, refreshCount: refresh)
        }
        sections.removeAll(where: { $0.id == "application" })
        sections.insert(LoaderSection(id: "application", title: "Application", entries: appEntries), at: 0)
        setVisible(true)
        reevaluate()
    }

    /// Marks an Application resource's reload as finished. `loaded` is the
    /// number of items that decoded successfully; the entry's `total` (seeded
    /// at start) determines the final mark: none failed → success, all failed
    /// → failed, some failed → warning. No-op when no entry exists for the
    /// resource (e.g. the event arrived without a preceding start, or the
    /// loader is idle).
    func markApplicationCompleted(_ resource: AppResource, loaded: Int) {
        guard mode != .idle else { return }
        guard var section = sections.first(where: { $0.id == "application" }),
              let idx = section.entries.firstIndex(where: { $0.id == resource.id }) else { return }
        let total = section.entries[idx].total
        let refresh = section.entries[idx].refreshCount
        let failed = max(0, total - loaded)
        let status: LoaderStatus
        if total <= 0 {
            status = .success
        } else if failed == 0 {
            status = .success
        } else if failed >= total {
            status = .failed
        } else {
            status = .warning
        }
        section.entries[idx].status = status
        // On success keep the batch-relative subtitle (e.g. "1 entry"); on
        // failure show how many didn't decode.
        section.entries[idx].detail = failed > 0 ? "\(failed) failed" : resourceSubtitle(resource, count: refresh)
        replaceSection(section)
        reevaluate()
    }

    /// Marks the chats row complete from a [`ChatSyncStats`](src/ChatStore.swift)
    /// result. The subtitle is "<total> (<freshCached> cached)" — the gap
    /// between total and freshCached is the number of files re-decoded this
    /// launch. Any decode failures flip the row to warning/failed and are noted.
    func markChatsCompleted(total: Int, freshCached: Int, failed: Int) {
        guard mode != .idle else { return }
        guard var section = sections.first(where: { $0.id == "application" }),
              let idx = section.entries.firstIndex(where: { $0.id == AppResource.chats.id }) else { return }
        let reRead = max(0, total - freshCached)
        let status: LoaderStatus
        if total <= 0 || failed == 0 {
            status = .success
        } else if failed >= reRead {
            status = .failed
        } else {
            status = .warning
        }
        section.entries[idx].status = status
        var detail = "\(loaderPluralized(total, singular: "entry", plural: "entries")) (\(freshCached) cached)"
        if failed > 0 { detail += ", \(failed) failed" }
        section.entries[idx].detail = detail
        replaceSection(section)
        reevaluate()
    }

    // MARK: - MCP column

    /// Updates the MCPs column from a configuration-state snapshot. During
    /// startup, statuses are merged by name into the seeded entries. During
    /// usage/idle, the snapshot's entries become the MCPs column (one entry
    /// for a single reconfigure, all entries for a full reinitialize).
    func setMCPState(_ state: MCPConfigurationState) {
        let entries = state.entries.map { e in
            LoaderEntry(id: e.name, label: e.name, status: LoaderStatus(e.status), detail: mcpDetail(e) ?? "pending", total: 1, refreshCount: 1)
        }
        if mode == .startup {
            guard var section = sections.first(where: { $0.id == "mcps" }) else { return }
            for e in entries {
                if let idx = section.entries.firstIndex(where: { $0.id == e.id }) {
                    section.entries[idx].status = e.status
                    // Keep "pending" as the subtitle until a real tool count /
                    // error arrives — don't blank it out for transient states.
                    section.entries[idx].detail = e.detail
                } else {
                    section.entries.append(e)
                }
            }
            replaceSection(section)
        } else {
            guard !entries.isEmpty else { return }
            hideTask?.cancel()
            hideTask = nil
            // New usage pass: drop any stale columns from a previous pass.
            if mode == .idle {
                mode = .usage
                sections = []
            }
            sections.removeAll(where: { $0.id == "mcps" })
            let mcpSection = LoaderSection(id: "mcps", title: "MCPs", entries: entries)
            if let appIdx = sections.firstIndex(where: { $0.id == "application" }) {
                sections.insert(mcpSection, at: appIdx + 1)
            } else {
                sections.append(mcpSection)
            }
            setVisible(true)
        }
        reevaluate()
    }

    // MARK: - Internals

    private func mcpDetail(_ e: MCPConfigurationEntry) -> String? {
        switch e.status {
        case .success: return e.toolCount.map { loaderPluralized($0, singular: "tool", plural: "tools") }
        case .failed: return e.errorMessage
        default: return nil
        }
    }

    /// Subtitle for an Application row. Configuration is always a single
    /// fixed descriptor; everything else is "<n> entr(y/ies)".
    private func resourceSubtitle(_ resource: AppResource, count: Int) -> String {
        switch resource {
        case .configuration: return "main application config"
        case .chats: return loaderPluralized(count, singular: "entry", plural: "entries")
        default: return loaderPluralized(count, singular: "entry", plural: "entries")
        }
    }

    private func replaceSection(_ section: LoaderSection) {
        if let idx = sections.firstIndex(where: { $0.id == section.id }) {
            sections[idx] = section
        }
    }

    /// Drives visibility: while any entry is pending/in-progress the loader
    /// stays visible; once everything is settled, schedules a 1-second display
    /// delay before hiding (so the user can read the final results).
    private func reevaluate() {
        let busy = sections.contains { section in
            section.entries.contains { $0.status == .pending || $0.status == .inProgress }
        }
        if busy {
            hideTask?.cancel()
            hideTask = nil
            setVisible(true)
        } else {
            // Everything has settled: the 1-second results display is starting.
            // During startup this is the signal that the main window may now be
            // revealed (it's been kept invisible while the loader ran).
            if mode == .startup && !startupReadyFired {
                startupReadyFired = true
                startupReadyHandler?()
            }
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    private func hide() {
        setVisible(false)
        mode = .idle
    }
}
