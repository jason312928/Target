import Foundation

struct JSONLineNumberCalculation {
    struct VisibleLine: Equatable {
        let number: Int
        let utf16Offset: Int
    }

    static func lineStartOffsets(in text: String) -> [Int] {
        let utf16 = Array(text.utf16)
        var offsets = [0]
        var index = 0

        while index < utf16.count {
            let codeUnit = utf16[index]
            if codeUnit == 0x000D {
                index += 1
                if index < utf16.count, utf16[index] == 0x000A {
                    index += 1
                }
                offsets.append(index)
            } else if codeUnit == 0x000A || codeUnit == 0x2028 || codeUnit == 0x2029 {
                index += 1
                offsets.append(index)
            } else {
                index += 1
            }
        }

        return offsets
    }

    static func visibleLines(
        lineStartOffsets: [Int],
        textUTF16Length: Int,
        visibleRange: NSRange
    ) -> [VisibleLine] {
        guard !lineStartOffsets.isEmpty else { return [] }

        let textLength = max(0, textUTF16Length)
        let visibleStart = min(visibleRange.location, textLength)
        let remainingLength = textLength - visibleStart
        let visibleLength = min(visibleRange.length, remainingLength)
        let visibleEnd = visibleStart + visibleLength
        let firstIndex = containingLineIndex(for: visibleStart, in: lineStartOffsets)

        var lines: [VisibleLine] = []
        var index = firstIndex
        let includeOnlyContainingLine = visibleLength == 0

        while index < lineStartOffsets.count {
            let offset = lineStartOffsets[index]
            guard offset <= textLength else { break }
            if !includeOnlyContainingLine, offset >= visibleEnd, index != firstIndex { break }

            lines.append(VisibleLine(number: index + 1, utf16Offset: offset))
            if includeOnlyContainingLine { break }

            let nextIndex = index + 1
            guard nextIndex > index else { break }
            index = nextIndex
        }

        return lines
    }

    private static func containingLineIndex(for offset: Int, in lineStartOffsets: [Int]) -> Int {
        var lowerBound = 0
        var upperBound = lineStartOffsets.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if lineStartOffsets[middle] <= offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return max(0, lowerBound - 1)
    }
}
