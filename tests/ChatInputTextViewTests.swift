import AppKit
import Testing

@testable import iCanHazAI

/// Tests for [`ChatInputTextView`](src/ChatInput/ChatInputTextView.swift):
/// height measurement (which drives how tall the input bar grows) and the
/// Return-key policy.
extension AllAppTests {

    @Suite("Chat input text view")
    @MainActor
    struct ChatInputTextViewTests {

        private func makeView(width: CGFloat = 300) -> ChatInputTextView {
            let tv = ChatInputTextView()
            tv.setFrameSize(NSSize(width: width, height: ChatInputTextView.lineHeight))
            return tv
        }

        private var oneLine: CGFloat { ChatInputTextView.lineHeight }
        private var lineFragment: CGFloat { ChatInputTextView.lineHeight - ChatInputTextView.insets.height * 2 }

        private func keyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)!
        }

        // MARK: Height

        @Test("an empty field is one line tall")
        func emptyIsOneLine() {
            #expect(makeView().contentHeight == oneLine)
        }

        @Test("a single line of text is one line tall")
        func singleLine() {
            let tv = makeView()
            tv.string = "hello"
            #expect(tv.contentHeight == oneLine)
        }

        @Test("height grows by one line fragment per line")
        func growsPerLine() {
            let tv = makeView()
            tv.string = "a\nb\nc\nd"
            #expect(abs(tv.contentHeight - (oneLine + 3 * lineFragment)) <= 1)
        }

        @Test("a trailing newline counts as a new, empty line")
        func trailingNewline() {
            let tv = makeView()
            tv.string = "a\n"
            #expect(abs(tv.contentHeight - (oneLine + lineFragment)) <= 1)
        }

        @Test("long text wraps at the view width")
        func wraps() {
            let tv = makeView(width: 120)
            tv.string = String(repeating: "word ", count: 40)
            #expect(tv.contentHeight > oneLine + 3 * lineFragment)
        }

        @Test("narrowing the view re-wraps the text")
        func rewrapsOnResize() {
            let tv = makeView(width: 900)
            tv.string = String(repeating: "word ", count: 40)
            let wide = tv.contentHeight
            tv.setFrameSize(NSSize(width: 150, height: tv.frame.height))
            #expect(tv.contentHeight > wide)
        }

        @Test("without a width the measurement falls back to one line")
        func zeroWidthFallback() {
            let tv = ChatInputTextView()
            tv.string = String(repeating: "word ", count: 40)
            #expect(tv.contentHeight == oneLine)
        }

        @Test("blank text is detected without copying the string")
        func nonBlankDetection() {
            let tv = makeView()
            #expect(!tv.hasNonBlankText)
            tv.string = " \n\t  "
            #expect(!tv.hasNonBlankText)
            tv.string = " \n x "
            #expect(tv.hasNonBlankText)
        }

        // MARK: Keys

        @Test("Return sends")
        func returnSends() {
            let tv = makeView()
            var sent = 0
            tv.returnHandler = {
                sent += 1
                return true
            }
            tv.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))
            #expect(sent == 1)
            #expect(tv.string.isEmpty)
        }

        @Test("keypad Enter sends")
        func keypadEnterSends() {
            let tv = makeView()
            var sent = 0
            tv.returnHandler = {
                sent += 1
                return true
            }
            tv.keyDown(with: keyEvent(keyCode: 76, characters: "\u{3}"))
            #expect(sent == 1)
        }

        @Test("Shift+Return does not send")
        func shiftReturnDoesNotSend() {
            let tv = makeView()
            var sent = 0
            tv.returnHandler = {
                sent += 1
                return true
            }
            tv.keyDown(with: keyEvent(keyCode: 36, characters: "\r", modifiers: .shift))
            #expect(sent == 0)
        }

        @Test("Return while an input method is composing does not send")
        func returnDuringCompositionDoesNotSend() {
            let tv = makeView()
            var sent = 0
            tv.returnHandler = {
                sent += 1
                return true
            }
            tv.setMarkedText(
                "に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            #expect(tv.hasMarkedText())
            tv.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))
            #expect(sent == 0)
        }

        @Test("a handler that declines leaves Return to the text view")
        func declinedReturnFallsThrough() {
            let tv = makeView()
            var asked = 0
            tv.returnHandler = {
                asked += 1
                return false
            }
            tv.keyDown(with: keyEvent(keyCode: 36, characters: "\r"))
            #expect(asked == 1)
        }

        // MARK: Paste

        @Test("paste is offered to the attachment handler first")
        func pasteOffered() {
            let tv = makeView()
            var offered = 0
            tv.attachmentPasteHandler = {
                offered += 1
                return true
            }
            tv.paste(nil)
            #expect(offered == 1)
        }

        @Test("file drags are left to the chat pane")
        func fileDragsRejected() {
            let types = makeView().acceptableDragTypes
            #expect(!types.contains(.fileURL))
            #expect(!types.contains(.tiff))
        }
    }
}
