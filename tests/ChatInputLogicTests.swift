import CoreGraphics
import Foundation
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
            ChatInputFacts(hasValidRole: true, hasModel: true)
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

        @Test("a missing role or model blocks sending")
        func missingRoleOrModel() {
            var noRole = ready()
            noRole.hasValidRole = false
            #expect(!noRole.actionEnabled(hasText: true, hasAttachments: false))
            var noModel = ready()
            noModel.hasModel = false
            #expect(!noModel.actionEnabled(hasText: true, hasAttachments: false))
        }

        @Test("a required working directory blocks sending")
        func workdirRequired() {
            var facts = ready()
            facts.workdirRequired = true
            #expect(!facts.actionEnabled(hasText: true, hasAttachments: true))
        }

        @Test("queued messages enable sending with an empty input")
        func queuedMessagesEnable() {
            var facts = ready()
            facts.queuedCount = 2
            #expect(facts.actionEnabled(hasText: false, hasAttachments: false))
            facts.hasModel = false
            #expect(!facts.actionEnabled(hasText: false, hasAttachments: false))
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

    @Suite("Queued messages")
    struct QueuedMessageTests {

        private func attachment(_ name: String) -> PendingAttachment {
            PendingAttachment(data: Data(name.utf8), kind: .text, originalName: name)
        }

        @Test("combining joins texts with a blank line and keeps attachment order")
        func combine() {
            let a = QueuedMessage(text: "first", attachments: [attachment("a")])
            let b = QueuedMessage(text: "second")
            let c = QueuedMessage(text: "third", attachments: [attachment("c")])
            let combined = QueuedMessage.combine([a, b, c])
            #expect(combined.text == "first\n\nsecond\n\nthird")
            #expect(combined.attachments.map(\.originalName) == ["a", "c"])
        }

        @Test("attachment-only messages add no blank separators")
        func combineAttachmentOnly() {
            let a = QueuedMessage(text: "", attachments: [attachment("a")])
            let b = QueuedMessage(text: "hello")
            #expect(QueuedMessage.combine([a, b]).text == "hello")
            #expect(QueuedMessage.combine([a]).text == "")
        }

        @Test("the preview is one line and counts attachments")
        func preview() {
            #expect(QueuedMessage(text: "a\nb\n\nc").preview == "a b c")
            #expect(
                QueuedMessage(text: "hi", attachments: [attachment("x"), attachment("y")]).preview == "\u{1F4CE}2 hi")
            #expect(QueuedMessage(text: "", attachments: [attachment("x")]).preview == "\u{1F4CE}1")
        }

        @Test("the queue takes part in record equality")
        func recordEquality() {
            var a = ChatRecord(filename: "x.json")
            let b = a
            a.queuedMessages = [QueuedMessage(text: "q")]
            #expect(a != b)
            #expect(AppViewModel.recordsUIRelevantChanged(from: [b], to: [a]))
        }
    }
}
