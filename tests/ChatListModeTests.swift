import Foundation
import Testing

@testable import iCanHazAI

/// Tests for the chat list mode filtering logic:
/// [`AppViewModel.chatMatchesDirectory`](src/App/AppViewModel.swift).
/// Pure logic (no UI), so it can be unit-tested directly.
extension AllAppTests {

    @Suite("ChatListMode")
    struct ChatListModeTests {

        /// Builds a `ChatSummary` with a given role and working directory.
        private func summary(
            _ id: String,
            role: String? = nil,
            workingDirectory: String? = nil
        ) -> ChatSummary {
            ChatSummary(
                record: ChatRecord(
                    filename: id,
                    chat: nil,
                    cachedRole: role,
                    cachedWorkingDirectory: workingDirectory
                ))
        }

        // MARK: - Directory matching

        @Test("chat with matching directory passes the filter")
        func matchingDirectory() {
            let chat = summary("a.json", workingDirectory: "/Users/alice/projects")
            #expect(AppViewModel.chatMatchesDirectory(chat, directory: "/Users/alice/projects"))
        }

        @Test("chat with non-matching directory fails the filter")
        func nonMatchingDirectory() {
            let chat = summary("a.json", workingDirectory: "/Users/alice/projects")
            #expect(!AppViewModel.chatMatchesDirectory(chat, directory: "/Users/alice/other"))
        }

        @Test("chat with no directory matches the home filter")
        func noDirectoryMatchesHome() {
            let chat = summary("a.json", workingDirectory: nil)
            #expect(AppViewModel.chatMatchesDirectory(chat, directory: AppViewModel.homeDirectoryPath))
        }

        @Test("chat with no directory does not match a non-home filter")
        func noDirectoryDoesNotMatchNonHome() {
            let chat = summary("a.json", workingDirectory: nil)
            #expect(!AppViewModel.chatMatchesDirectory(chat, directory: "/Users/alice/projects"))
        }

        @Test("chat with empty directory matches the home filter")
        func emptyDirectoryMatchesHome() {
            let chat = summary("a.json", workingDirectory: "")
            #expect(AppViewModel.chatMatchesDirectory(chat, directory: AppViewModel.homeDirectoryPath))
        }

        @Test("tilde-expanded paths are normalized for comparison")
        func tildeNormalization() {
            let home = AppViewModel.homeDirectoryPath
            let chat = summary("a.json", workingDirectory: home)
            // "~" should expand to the home directory and match.
            #expect(AppViewModel.chatMatchesDirectory(chat, directory: "~"))
        }

        @Test("SSH directory specs are matched verbatim")
        func sshDirectoryMatch() {
            let chat = summary("a.json", workingDirectory: "host:/var/www")
            #expect(AppViewModel.chatMatchesDirectory(chat, directory: "host:/var/www"))
            #expect(!AppViewModel.chatMatchesDirectory(chat, directory: "host:/other"))
        }

        @Test("SSH chat does not match home filter")
        func sshDoesNotMatchHome() {
            let chat = summary("a.json", workingDirectory: "host:/var/www")
            #expect(!AppViewModel.chatMatchesDirectory(chat, directory: AppViewModel.homeDirectoryPath))
        }

        // MARK: - ChatListMode enum

        @Test("ChatListMode has all three cases")
        func allModes() {
            #expect(AppViewModel.ChatListMode.allCases.count == 3)
            #expect(AppViewModel.ChatListMode.allCases.contains(.all))
            #expect(AppViewModel.ChatListMode.allCases.contains(.role))
            #expect(AppViewModel.ChatListMode.allCases.contains(.directory))
        }

        @Test("ChatListMode raw values are lowercase strings")
        func rawValues() {
            #expect(AppViewModel.ChatListMode.all.rawValue == "all")
            #expect(AppViewModel.ChatListMode.role.rawValue == "role")
            #expect(AppViewModel.ChatListMode.directory.rawValue == "directory")
        }

        @Test("ChatListMode initializes from valid raw values")
        func fromRawValue() {
            #expect(AppViewModel.ChatListMode(rawValue: "all") == .all)
            #expect(AppViewModel.ChatListMode(rawValue: "role") == .role)
            #expect(AppViewModel.ChatListMode(rawValue: "directory") == .directory)
        }

        @Test("ChatListMode returns nil for invalid raw values")
        func invalidRawValue() {
            #expect(AppViewModel.ChatListMode(rawValue: "invalid") == nil)
            #expect(AppViewModel.ChatListMode(rawValue: "") == nil)
        }
    }
}  // extension AllAppTests
