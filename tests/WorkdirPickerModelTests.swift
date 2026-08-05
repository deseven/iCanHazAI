import Testing
import Foundation
@testable import iCanHazAI

/// Unit tests for the working-directory picker's search model: query
/// classification ([`WorkdirQuery`](src/Views/WorkdirPickerModel.swift)),
/// result assembly ([`WorkdirItemsBuilder`](src/Views/WorkdirPickerModel.swift)),
/// local subdirectory listing, the fuzzy search wrapper, and the MRU
/// recents logic in `AppViewModel`. No network — the SSH lister is not
/// covered here.
extension AllAppTests {

@Suite("Workdir picker: query parsing")
struct WorkdirQueryTests {

    @Test("empty and whitespace queries are empty")
    func empty() {
        #expect(WorkdirQuery.parse("") == .empty)
        #expect(WorkdirQuery.parse("   ") == .empty)
    }

    @Test("free text is a plain (fuzzy-only) query")
    func plain() {
        #expect(WorkdirQuery.parse("website") == .plain)
        #expect(WorkdirQuery.parse("foo/bar") == .plain)
        // Malformed SSH spec (whitespace in host) degrades to plain.
        #expect(WorkdirQuery.parse("ho st:/x") == .plain)
    }

    @Test("absolute local paths split into dir and name prefix")
    func localAbsolute() {
        #expect(WorkdirQuery.parse("/v") == .local(dir: "/", prefix: "v", full: "/v"))
        #expect(WorkdirQuery.parse("/var/www") == .local(dir: "/var", prefix: "www", full: "/var/www"))
        #expect(WorkdirQuery.parse("/") == .local(dir: "/", prefix: "", full: "/"))
    }

    @Test("trailing slashes are stripped and mean the typed path itself")
    func localTrailingSlash() {
        #expect(WorkdirQuery.parse("/var/www/") == .local(dir: "/var/www", prefix: "", full: "/var/www"))
        #expect(WorkdirQuery.parse("/var//") == .local(dir: "/var", prefix: "", full: "/var"))
    }

    @Test("tilde queries expand against the home directory")
    func localTilde() {
        let home = NSHomeDirectory()
        // A bare ~ is the home directory itself, not a prefix inside it.
        #expect(WorkdirQuery.parse("~") == .local(dir: home, prefix: "", full: home))
        #expect(WorkdirQuery.parse("~/") == .local(dir: home, prefix: "", full: home))
        #expect(WorkdirQuery.parse("~/w") == .local(dir: home, prefix: "w", full: home + "/w"))
        #expect(WorkdirQuery.parse("~/a/b") == .local(dir: home + "/a", prefix: "b", full: home + "/a/b"))
    }

    @Test("ssh specs keep the host and the cleaned remote path")
    func ssh() {
        #expect(WorkdirQuery.parse("test:") == .ssh(host: "test", path: nil))
        #expect(WorkdirQuery.parse("test:/") == .ssh(host: "test", path: "/"))
        #expect(WorkdirQuery.parse("test:/v") == .ssh(host: "test", path: "/v"))
        #expect(WorkdirQuery.parse("test:/var/www") == .ssh(host: "test", path: "/var/www"))
        #expect(WorkdirQuery.parse("user@test:/var/www") == .ssh(host: "user@test", path: "/var/www"))
    }

    @Test("ssh trailing slashes are stripped")
    func sshTrailingSlash() {
        #expect(WorkdirQuery.parse("test:/var/") == .ssh(host: "test", path: "/var"))
        #expect(WorkdirQuery.parse("test:/var/www/") == .ssh(host: "test", path: "/var/www"))
    }

    @Test("splitDirPrefix handles roots, complete dirs, and prefixes")
    func splitDirPrefix() {
        #expect(WorkdirQuery.splitDirPrefix("/", completeDir: false) == ("/", ""))
        #expect(WorkdirQuery.splitDirPrefix("/var", completeDir: false) == ("/", "var"))
        #expect(WorkdirQuery.splitDirPrefix("/var/www", completeDir: false) == ("/var", "www"))
        #expect(WorkdirQuery.splitDirPrefix("/var/www", completeDir: true) == ("/var/www", ""))
    }
}

@Suite("Workdir picker: result assembly")
struct WorkdirItemsBuilderTests {

    /// Recents mirroring the feature examples: one SSH spec, one local dir.
    private var recents: [String] { ["test:/var/www/website", NSHomeDirectory() + "/my-project"] }

    @Test("empty query lists the recents in order")
    func emptyQuery() {
        let items = WorkdirItemsBuilder.build(query: "", recents: recents, typedDir: nil, children: [])
        #expect(items == [.recent("test:/var/www/website"), .recent(NSHomeDirectory() + "/my-project")])
    }

    @Test("text query filters recents by substring against their display form")
    func filteredRecents() {
        // "website" only matches the SSH recent.
        #expect(WorkdirItemsBuilder.build(query: "website", recents: recents, typedDir: nil, children: [])
            == [.recent("test:/var/www/website")])
        // "~" matches the local recent via its tilde-abbreviated display form.
        #expect(WorkdirItemsBuilder.build(query: "~", recents: recents, typedDir: nil, children: [])
            == [.recent(NSHomeDirectory() + "/my-project")])
        // Substring (not fuzzy): "wbs" matches nothing.
        #expect(WorkdirItemsBuilder.build(query: "wbs", recents: recents, typedDir: nil, children: []).isEmpty)
        // Case-insensitive.
        #expect(WorkdirItemsBuilder.build(query: "WEBSITE", recents: recents, typedDir: nil, children: [])
            == [.recent("test:/var/www/website")])
    }

    @Test("existing typed directory shows after the recents, before children")
    func ordering() {
        let home = NSHomeDirectory()
        let children = [home + "/whatever", home + "/wombat"]
        let items = WorkdirItemsBuilder.build(query: "~/w", recents: recents, typedDir: home + "/weird", children: children)
        #expect(items == [.directory(home + "/weird"), .directory(home + "/whatever"), .directory(home + "/wombat")])
    }

    @Test("a perfect match in the recents suppresses the typed-directory row")
    func perfectMatchSuppressesTyped() {
        let home = NSHomeDirectory()
        let items = WorkdirItemsBuilder.build(query: "~/my-project", recents: recents, typedDir: home + "/my-project", children: [])
        #expect(items == [.recent(home + "/my-project")])
    }

    @Test("children already in the recents or equal to the typed row are skipped")
    func childrenDeduped() {
        let home = NSHomeDirectory()
        let children = [home + "/my-project", home + "/other"]
        let items = WorkdirItemsBuilder.build(query: "~", recents: recents, typedDir: home, children: children)
        #expect(items == [
            .recent(home + "/my-project"),
            .directory(home),
            .directory(home + "/other"),
        ])
    }

    @Test("children are capped at the limit")
    func childrenCapped() {
        let children = (1...20).map { "/var/dir\($0)" }
        let items = WorkdirItemsBuilder.build(query: "/var/d", recents: [], typedDir: nil, children: children)
        #expect(items.count == WorkdirItemsBuilder.childLimit)
        #expect(items.allSatisfy { if case .directory = $0 { return true }; return false })
    }

    @Test("ssh browsing results follow the recents")
    func sshResults() {
        let children = ["test:/home", "test:/opt", "test:/var"]
        let items = WorkdirItemsBuilder.build(query: "test:", recents: recents, typedDir: nil, children: children)
        #expect(items == [
            .recent("test:/var/www/website"),
            .directory("test:/home"),
            .directory("test:/opt"),
            .directory("test:/var"),
        ])
    }
}

@Suite("Workdir picker: local subdirectory listing")
struct WorkdirLocalListingTests {

    /// Builds a temp tree: alpha/, Beta/, .hidden/, and a file; removed on
    /// exit. The root path is pre-standardized because `localChildren`
    /// standardizes its results (resolving the /var → /private/var symlink
    /// in macOS temp paths).
    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: (FileManager.default.temporaryDirectory
            .appendingPathComponent("ichai-picker-test-" + UUID().uuidString, isDirectory: true).path as NSString).standardizingPath,
            isDirectory: true)
        for dir in ["alpha", "Beta", ".hidden", "alpha/inner"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent("afile"))
        return root
    }

    @Test("lists only directories, sorted, files and hidden dirs skipped")
    func basicListing() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let children = WorkdirQuery.localChildren(dir: root.path, prefix: "")
        #expect(children == [root.appendingPathComponent("Beta").path, root.appendingPathComponent("alpha").path])
    }

    @Test("prefix filtering is case-insensitive and anchored")
    func prefixFiltering() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkdirQuery.localChildren(dir: root.path, prefix: "A") == [root.appendingPathComponent("alpha").path])
        #expect(WorkdirQuery.localChildren(dir: root.path, prefix: "b") == [root.appendingPathComponent("Beta").path])
        // Anchored: "lph" must not match "alpha".
        #expect(WorkdirQuery.localChildren(dir: root.path, prefix: "lph").isEmpty)
    }

    @Test("hidden entries appear only when the prefix starts with a dot")
    func hiddenEntries() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(WorkdirQuery.localChildren(dir: root.path, prefix: ".") == [root.appendingPathComponent(".hidden").path])
    }

    @Test("unreadable or missing directories yield no results")
    func missingDir() {
        #expect(WorkdirQuery.localChildren(dir: "/nonexistent-ichai-test", prefix: "").isEmpty)
    }
}

@Suite("FuzzySearch")
struct FuzzySearchTests {

    @Test("empty query returns candidates unchanged")
    func emptyQuery() {
        #expect(FuzzySearch.rank(["b", "a"], query: "") == ["b", "a"])
        #expect(FuzzySearch.rank(["b", "a"], query: "  ") == ["b", "a"])
    }

    @Test("non-matching candidates are dropped, best match first")
    func ranking() {
        let ranked = FuzzySearch.rank(["Developer", "Architect", "Assistant"], query: "dev")
        #expect(ranked.first == "Developer")
        #expect(!ranked.contains("Assistant"))
    }

    @Test("multi-key ranking uses the best key score")
    func multiKey() {
        struct Item: Equatable { let name: String; let desc: String }
        let items = [
            Item(name: "Configurator", desc: "Manages configuration files"),
            Item(name: "Assistant", desc: "General help, no tools"),
        ]
        let ranked = FuzzySearch.rank(items, query: "configuration") { [$0.name, $0.desc] }
        #expect(ranked.first?.name == "Configurator")
        #expect(!ranked.contains(Item(name: "Assistant", desc: "General help, no tools")))
    }
}

@Suite("Workdir recents (MRU list)")
struct WorkdirRecentsTests {

    @Test("picking a directory moves it to the front, deduped")
    func moveToFront() {
        let list = AppViewModel.recentDirectories(inserting: "/a", into: ["/b", "/a", "/c"])
        #expect(list == ["/a", "/b", "/c"])
    }

    @Test("the list is capped at the limit, dropping the oldest")
    func capped() {
        let full = (1...AppViewModel.workingDirectoryRecentLimit).map { "/dir\($0)" }
        let list = AppViewModel.recentDirectories(inserting: "/new", into: full)
        #expect(list.count == AppViewModel.workingDirectoryRecentLimit)
        #expect(list.first == "/new")
        #expect(!list.contains("/dir\(AppViewModel.workingDirectoryRecentLimit)"))
    }

    @Test("ssh specs are stored verbatim, local paths standardized")
    func normalization() {
        #expect(AppViewModel.normalizeWorkingDirectory("test:/var/www") == "test:/var/www")
        #expect(AppViewModel.normalizeWorkingDirectory("  test:/var/www  ") == "test:/var/www")
        #expect(AppViewModel.normalizeWorkingDirectory("~/x") == NSHomeDirectory() + "/x")
        #expect(AppViewModel.normalizeWorkingDirectory("/a/./b/../c") == "/a/c")
    }
}
}
