import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {
    @Suite("Model picker presentation")
    struct ModelPickerStateTests {

        private func decide(
            model: String? = nil, chatLoaded: Bool = true, hasProviders: Bool = true, roleValid: Bool = true,
            anotherPickerShowing: Bool = false, dismissed: Bool = false
        ) -> Bool {
            AppViewModel.shouldPresentModelPicker(
                chat: chatLoaded ? Chat(model: model) : nil, hasProviders: hasProviders, roleValid: roleValid,
                anotherPickerShowing: anotherPickerShowing, dismissed: dismissed)
        }

        @Test("a loaded chat without a model gets the picker")
        func presentsForModellessChat() {
            #expect(decide())
        }

        @Test("a chat that has a model never gets it")
        func hasModel() {
            #expect(!decide(model: "openai:gpt-5"))
        }

        @Test("nothing is presented before the chat is loaded")
        func notLoaded() {
            #expect(!decide(chatLoaded: false))
        }

        @Test("no providers, no picker")
        func noProviders() {
            #expect(!decide(hasProviders: false))
        }

        @Test("a missing role gets its picker first")
        func roleMissing() {
            #expect(!decide(roleValid: false))
        }

        @Test("pickers never stack")
        func noStacking() {
            #expect(!decide(anotherPickerShowing: true))
        }

        @Test("a dismissed picker isn't shown again for that chat")
        func dismissal() {
            #expect(!decide(dismissed: true))
        }
    }
}
