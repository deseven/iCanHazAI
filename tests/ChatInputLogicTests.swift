import CoreGraphics
import Testing

@testable import iCanHazAI

/// Pure logic behind the chat input: the height tween and the send-button rules.
extension AllAppTests {

    @Suite("Value tween")
    struct ValueTweenTests {

        @Test("a new tween is already finished")
        func startsFinished() {
            let tween = ValueTween(value: 40)
            #expect(tween.isFinished)
            #expect(tween.value == 40)
        }

        @Test("moves from the start value to the target over its duration")
        func interpolates() {
            var tween = ValueTween(value: 0)
            tween.retarget(to: 100, now: 10, duration: 0.2)
            #expect(!tween.isFinished)
            #expect(tween.advance(now: 10) == 0)
            let mid = tween.advance(now: 10.1)
            #expect(mid > 50 && mid < 100)  // ease-out: past halfway at half time
            #expect(tween.advance(now: 10.2) == 100)
            #expect(tween.isFinished)
        }

        @Test("time past the end lands exactly on the target")
        func clampsAtEnd() {
            var tween = ValueTween(value: 0)
            tween.retarget(to: 100, now: 0, duration: 0.2)
            #expect(tween.advance(now: 5) == 100)
        }

        @Test("retargeting continues from the current value, not the old target")
        func retargetStartsFromCurrent() {
            var tween = ValueTween(value: 0)
            tween.retarget(to: 100, now: 0, duration: 0.2)
            let current = tween.advance(now: 0.1)
            tween.retarget(to: 200, now: 0.1, duration: 0.2)
            #expect(tween.advance(now: 0.1) == current)
            #expect(tween.advance(now: 0.3) == 200)
        }

        @Test("retargeting back toward the start reverses smoothly")
        func reverses() {
            var tween = ValueTween(value: 50)
            tween.retarget(to: 100, now: 0, duration: 0.2)
            let current = tween.advance(now: 0.05)
            tween.retarget(to: 50, now: 0.05, duration: 0.2)
            let next = tween.advance(now: 0.1)
            #expect(next < current)
            #expect(next >= 50)
        }

        @Test("jump cancels the animation")
        func jumpCancels() {
            var tween = ValueTween(value: 0)
            tween.retarget(to: 100, now: 0, duration: 0.2)
            tween.jump(to: 30)
            #expect(tween.isFinished)
            #expect(tween.value == 30)
            #expect(tween.advance(now: 1) == 30)
        }

        @Test("a zero duration applies immediately")
        func zeroDuration() {
            var tween = ValueTween(value: 0)
            tween.retarget(to: 100, now: 0, duration: 0)
            #expect(tween.value == 100)
            #expect(tween.isFinished)
        }

        @Test("retargeting to the current target is a no-op")
        func sameTarget() {
            var tween = ValueTween(value: 10)
            tween.retarget(to: 10, now: 0, duration: 0.2)
            #expect(tween.isFinished)
        }
    }

    @Suite("Chat input facts")
    struct ChatInputFactsTests {

        private func ready() -> ChatInputFacts {
            ChatInputFacts(hasValidRole: true, hasConnection: true)
        }

        @Test("text or attachments enable sending")
        func contentEnables() {
            #expect(ready().actionEnabled(hasText: true, hasAttachments: false))
            #expect(ready().actionEnabled(hasText: false, hasAttachments: true))
        }

        @Test("empty input is disabled unless the last message is the user's")
        func emptyInput() {
            #expect(!ready().actionEnabled(hasText: false, hasAttachments: false))
            var facts = ready()
            facts.lastMessageIsFromUser = true
            #expect(facts.actionEnabled(hasText: false, hasAttachments: false))
        }

        @Test("a missing role or connection blocks sending")
        func missingRoleOrConnection() {
            var noRole = ready()
            noRole.hasValidRole = false
            #expect(!noRole.actionEnabled(hasText: true, hasAttachments: false))
            var noConnection = ready()
            noConnection.hasConnection = false
            #expect(!noConnection.actionEnabled(hasText: true, hasAttachments: false))
        }

        @Test("a required working directory blocks sending")
        func workdirRequired() {
            var facts = ready()
            facts.workdirRequired = true
            #expect(!facts.actionEnabled(hasText: true, hasAttachments: true))
        }

        @Test("while streaming the button stays enabled to stop")
        func streamingAlwaysEnabled() {
            var facts = ChatInputFacts()
            facts.isStreaming = true
            #expect(facts.actionEnabled(hasText: false, hasAttachments: false))
        }

        @Test("the input is disabled without a valid role")
        func inputDisabled() {
            #expect(ChatInputFacts().inputDisabled)
            #expect(!ready().inputDisabled)
        }
    }
}
