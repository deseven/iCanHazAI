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
