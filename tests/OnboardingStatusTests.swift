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

        @Test("only the onboarding flow may be shown while onboarding is active")
        func onboardingFlowSheets() {
            #expect(MainSheet.onboarding.isOnboardingFlow)
            #expect(MainSheet.providerWizard.isOnboardingFlow)
            #expect(MainSheet.settingsModelPicker(.defaultModel).isOnboardingFlow)
            #expect(MainSheet.settingsModelPicker(.utilityModel).isOnboardingFlow)
            #expect(!MainSheet.preferences.isOnboardingFlow)
            #expect(!MainSheet.mcpWizard.isOnboardingFlow)
            #expect(!MainSheet.modelPicker.isOnboardingFlow)
            #expect(!MainSheet.rolePicker.isOnboardingFlow)
        }
    }
}
