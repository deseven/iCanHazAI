// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// App identity shared by every outbound HTTP surface (LLM providers, web
/// tools, CLI). The version comes from the bundle's Info.plist; bare
/// executable runs (swift test, dev builds) fall back to "dev".
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
    }

    /// The User-Agent sent with all outbound requests: `ichai/<version>`.
    static var userAgent: String { "ichai/\(version)" }
}
