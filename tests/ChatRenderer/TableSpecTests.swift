import Foundation
import Testing

@testable import iCanHazAI

extension AllAppTests {

    @Suite("Table column widths")
    struct TableSpecTests {

        private let theme = Theme()

        private func spec(min: [CGFloat], max: [CGFloat], indent: CGFloat = 0) -> TableSpec {
            let s = TableSpec(columns: min.count, indent: indent, marginTop: 0, theme: theme)
            s.minWidths = min
            s.maxWidths = max
            return s
        }

        /// Space taken by borders and cell padding for `columns` columns.
        private func overhead(_ columns: Int) -> CGFloat {
            (theme.tableCellPadH * 2 + 1) * CGFloat(columns) + 1
        }

        @Test("natural widths are used when the table fits")
        func fits() {
            let s = spec(min: [20, 30], max: [100, 200])
            #expect(s.columnWidths(available: 300 + overhead(2)) == [100, 200])
            #expect(s.columnWidths(available: 1000) == [100, 200])
        }

        @Test("minimum widths are used when nothing fits")
        func nothingFits() {
            let s = spec(min: [60, 80], max: [100, 200])
            #expect(s.columnWidths(available: 100) == [60, 80])
            #expect(s.columnWidths(available: 140 + overhead(2)) == [60, 80])
        }

        @Test("in between, the spare room is shared in proportion to how much each column wants to grow")
        func between() {
            let s = spec(min: [20, 20], max: [60, 120])
            // Minimums need 40, maxima 180; with 100 available, 60 is spare of a possible 140.
            let widths = s.columnWidths(available: 100 + overhead(2))
            let first: CGFloat = floor(20 + 40 * 60 / 140)
            let second: CGFloat = floor(20 + 100 * 60 / 140)
            #expect(widths == [first, second])
            #expect(widths[0] >= 20 && widths[0] <= 60)
            #expect(widths[1] >= 20 && widths[1] <= 120)
            #expect(widths[0] + widths[1] <= 100)
            #expect(widths[1] > widths[0])
        }

        @Test("the indent of a table nested in a list reduces the available space")
        func indent() {
            let flat = spec(min: [20], max: [100])
            let nested = spec(min: [20], max: [100], indent: 40)
            let available = 100 + overhead(1)
            #expect(flat.columnWidths(available: available) == [100])
            #expect(nested.columnWidths(available: available)[0] < 100)
        }
    }
}
