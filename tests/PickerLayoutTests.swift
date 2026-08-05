import Testing
import Foundation
@testable import iCanHazAI

/// Unit tests for [`PickerLayout`](src/Views/PickerDialog.swift), the pure
/// layout math behind `PickerDialog`: the dialog has a fixed height of 80%
/// of the parent window's, and its top edge is anchored 15% below the
/// window's top.
extension AllAppTests {

@Suite("Picker dialog layout")
struct PickerLayoutTests {

    @Test("dialog height is a fixed fraction of the window height")
    func height() {
        #expect(PickerLayout.dialogHeight(windowHeight: 1000) == 800)
        #expect(PickerLayout.dialogHeight(windowHeight: 600) == 480)
    }

    @Test("sheet top edge sits 15% below the window top, centered horizontally")
    func anchor() {
        let parent = NSRect(x: 100, y: 100, width: 800, height: 1000)
        let size = NSSize(width: 400, height: 300)
        let origin = PickerLayout.sheetOrigin(parentFrame: parent, sheetSize: size)
        // Top edge: 100 + 1000 − 0.15×1000 = 950; origin.y = 950 − 300.
        #expect(origin.y == 650)
        // Centered: midX 500 − half of 400.
        #expect(origin.x == 300)
    }
}
}
