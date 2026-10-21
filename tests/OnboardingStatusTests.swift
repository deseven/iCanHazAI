import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("Onboarding requirements")
    struct OnboardingStatusTests {

        private func status(
            providers: Int = 1, defaultModel: String? = "openai:gpt-5", utility: String? = "openai:gpt-5-mini"
        )
            -> OnboardingStatus
        {
            OnboardingStatus(providerCount: providers, defaultModel: defaultModel, utilityModel: utility)
        }

        @Test("complete only when all three requirements are met")
        func complete() {
            #expect(status().isComplete)
            #expect(!status(providers: 0).isComplete)
            #expect(!status(defaultModel: nil).isComplete)
            #expect(!status(utility: nil).isComplete)
        }

        @Test("an empty model string counts as unset")
        func emptyModel() {
            #expect(!status(defaultModel: "").hasDefaultModel)
            #expect(!status(utility: "").hasUtilityModel)
        }

        @Test("models can't be picked without a provider")
        func pickingNeedsProvider() {
            #expect(!status(providers: 0, defaultModel: nil, utility: nil).canPickModels)
            #expect(status(providers: 1, defaultModel: nil, utility: nil).canPickModels)
        }

        @Test("each requirement is reported independently")
        func independent() {
            let s = status(providers: 2, defaultModel: "openai:gpt-5", utility: nil)
            #expect(s.hasProvider)
            #expect(s.hasDefaultModel)
            #expect(!s.hasUtilityModel)
        }

        @Test("the note names the lost model and its provider")
        func lostModelNote() {
            #expect(
                LostGeneralModels.note(for: .defaultModel, raw: "openai:gpt-5", displayName: nil, canPick: true)
                    == "Your default model gpt-5 from OpenAI is no longer available, please select a new one.")
            #expect(
                LostGeneralModels.note(
                    for: .utilityModel, raw: "ollama:llama3.2:latest", displayName: "Llama 3.2", canPick: true)
                    == "Your utility model Llama 3.2 from ollama is no longer available, please select a new one.")
        }

        @Test("the note asks for a provider first when none is left")
        func lostModelNoteWithoutProvider() {
            #expect(
                LostGeneralModels.note(for: .defaultModel, raw: "openai:gpt-5", displayName: nil, canPick: false)
                    == "Your default model gpt-5 from OpenAI is no longer available. Add a provider, then select a new model."
            )
        }

        @Test("the note falls back to the raw string for an unparsable model")
        func lostModelNoteUnparsable() {
            #expect(
                LostGeneralModels.note(for: .defaultModel, raw: "garbage", displayName: nil, canPick: true)
                    == "Your default model garbage is no longer available, please select a new one.")
        }

        @Test("lost models are addressed per setting and merge without dropping earlier ones")
        func lostModelsMerge() {
            var lost = LostGeneralModels()
            #expect(lost.isEmpty)
            lost[.defaultModel] = "openai:gpt-5"
            #expect(!lost.isEmpty)
            #expect(lost[.defaultModel] == "openai:gpt-5")
            #expect(lost[.utilityModel] == nil)

            lost.merge(LostGeneralModels(defaultModel: nil, utilityModel: "deepseek:flash"))
            #expect(lost.defaultModel == "openai:gpt-5")
            #expect(lost.utilityModel == "deepseek:flash")

            lost[.defaultModel] = nil
            lost[.utilityModel] = nil
            #expect(lost.isEmpty)
        }

        @Test("only the onboarding flow may be shown while onboarding is active")
        func onboardingFlowSheets() {
            #expect(MainSheet.onboarding.isOnboardingFlow)
            #expect(MainSheet.providerWizard().isOnboardingFlow)
            #expect(MainSheet.settingsModelPicker(.defaultModel).isOnboardingFlow)
            #expect(MainSheet.settingsModelPicker(.utilityModel).isOnboardingFlow)
            #expect(!MainSheet.preferences().isOnboardingFlow)
            #expect(!MainSheet.manageKeys.isOnboardingFlow)
            #expect(!MainSheet.mcpWizard.isOnboardingFlow)
            #expect(!MainSheet.webSearchWizard.isOnboardingFlow)
            #expect(!MainSheet.modelPicker.isOnboardingFlow)
            #expect(!MainSheet.rolePicker.isOnboardingFlow)
        }

        @Test("Manage Keys is an app-level sheet, and the wizard is one sheet whatever provider it starts on")
        func manageKeysSheets() {
            #expect(MainSheet.manageKeys.isAppLevel)
            #expect(MainSheet.providerWizard(.openai).isAppLevel)
            #expect(MainSheet.providerWizard(.openai).id == MainSheet.providerWizard().id)
            #expect(MainSheet.providerWizard(.openai).id != MainSheet.manageKeys.id)
            #expect(MainSheet.providerWizard(.openai) != MainSheet.providerWizard())
        }
    }
}
