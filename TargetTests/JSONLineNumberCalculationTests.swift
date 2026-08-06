import Foundation
import XCTest

@testable import Target

final class JSONLineNumberCalculationTests: XCTestCase {
    func testEmptyStringHasOneLineAtZero() {
        XCTAssertEqual(offsets(in: ""), [0])
    }

    func testOneLineHasOneLineAtZero() {
        XCTAssertEqual(offsets(in: "single line"), [0])
    }

    func testMultipleLinesUseUTF16Offsets() {
        XCTAssertEqual(offsets(in: "one\ntwo\nthree"), [0, 4, 8])
        XCTAssertEqual(offsets(in: "emoji \u{1F600}\nnext"), [0, 9])
    }

    func testTrailingNewlineIncludesTrailingEmptyLine() {
        XCTAssertEqual(offsets(in: "one\n"), [0, 4])
    }

    func testMultipleTrailingNewlinesIncludeEveryEmptyLine() {
        XCTAssertEqual(offsets(in: "one\n\n"), [0, 4, 5])
    }

    func testBlankLinesArePreserved() {
        XCTAssertEqual(offsets(in: "\n\nvalue\n\nnext"), [0, 1, 2, 8, 9])
    }

    func testVisibleRangeAtStartReturnsFirstVisibleLine() {
        XCTAssertEqual(visibleOffsets(in: "one\ntwo\nthree", range: NSRange(location: 0, length: 3)), [0])
    }

    func testVisibleRangeInMiddleStartsAtContainingLine() {
        XCTAssertEqual(visibleOffsets(in: "one\ntwo\nthree", range: NSRange(location: 5, length: 4)), [4, 8])
    }

    func testVisibleRangeAtEndReturnsLastLine() {
        let text = "one\ntwo\nthree"
        XCTAssertEqual(visibleOffsets(in: text, range: NSRange(location: text.utf16.count, length: 0)), [8])
    }

    func testVisibleRangeEndingAtNewlineBoundaryDoesNotAddNextLine() {
        XCTAssertEqual(visibleOffsets(in: "one\ntwo", range: NSRange(location: 0, length: 4)), [0])
    }

    func testZeroLengthVisibleRangeReturnsContainingLine() {
        XCTAssertEqual(visibleOffsets(in: "one\ntwo\nthree", range: NSRange(location: 4, length: 0)), [4])
    }

    func testVisibleRangeBeyondTextIsClamped() {
        XCTAssertEqual(visibleOffsets(in: "one\ntwo", range: NSRange(location: 999, length: 999)), [4])
    }

    func testOffsetsAreUniqueStrictlyIncreasingAndWithinUTF16Length() {
        let samples = [
            "",
            "one",
            "one\n",
            "one\n\n",
            "\n\nvalue\n\nnext",
            "emoji \u{1F600}\r\nwindows\rlegacy\u{2028}separator"
        ]

        for sample in samples {
            let result = offsets(in: sample)
            XCTAssertEqual(Set(result).count, result.count, "Duplicate offsets for \(sample.debugDescription)")
            XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy(<), "Offsets did not strictly increase")
            XCTAssertTrue(result.allSatisfy { (0...sample.utf16.count).contains($0) })
        }
    }

    private func offsets(in text: String) -> [Int] {
        JSONLineNumberCalculation.lineStartOffsets(in: text)
    }

    private func visibleOffsets(in text: String, range: NSRange) -> [Int] {
        JSONLineNumberCalculation.visibleLines(
            lineStartOffsets: offsets(in: text),
            textUTF16Length: text.utf16.count,
            visibleRange: range
        ).map(\.utf16Offset)
    }
}
