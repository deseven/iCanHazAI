// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// The three things the app needs before it is usable: a configured provider,
/// a default model and a utility model. Drives the onboarding sheet.
struct OnboardingStatus: Equatable {
    let hasProvider: Bool
    let hasDefaultModel: Bool
    let hasUtilityModel: Bool

    init(providerCount: Int, defaultModel: String?, utilityModel: String?) {
        hasProvider = providerCount > 0
        hasDefaultModel = !(defaultModel ?? "").isEmpty
        hasUtilityModel = !(utilityModel ?? "").isEmpty
    }

    var isComplete: Bool { hasProvider && hasDefaultModel && hasUtilityModel }

    /// Without a provider there is nothing to pick a model from.
    var canPickModels: Bool { hasProvider }
}

/// The `[general]` models (raw `provider:model-id`) that were reset because
/// they no longer resolve, so onboarding can say what happened.
struct LostGeneralModels: Sendable, Equatable {
    var defaultModel: String?
    var utilityModel: String?

    var isEmpty: Bool { defaultModel == nil && utilityModel == nil }

    subscript(setting: ModelSetting) -> String? {
        get {
            switch setting {
            case .defaultModel: return defaultModel
            case .utilityModel: return utilityModel
            }
        }
        set {
            switch setting {
            case .defaultModel: defaultModel = newValue
            case .utilityModel: utilityModel = newValue
            }
        }
    }

    mutating func merge(_ other: LostGeneralModels) {
        defaultModel = other.defaultModel ?? defaultModel
        utilityModel = other.utilityModel ?? utilityModel
    }

    /// The red note onboarding shows for a requirement that is unmet because
    /// its model went away. `displayName` is the catalog's name for the model
    /// when it is still known; `canPick` is false while no provider is left.
    static func note(for setting: ModelSetting, raw: String, displayName: String?, canPick: Bool) -> String {
        let kind = setting == .defaultModel ? "default" : "utility"
        let model: String
        if let id = ModelID(parsing: raw) {
            model = "\(displayName ?? id.name) from \(id.provider.displayName)"
        } else {
            model = raw
        }
        let prefix = "Your \(kind) model \(model) is no longer available"
        return canPick ? "\(prefix), please select a new one." : "\(prefix). Add a provider, then select a new model."
    }
}
