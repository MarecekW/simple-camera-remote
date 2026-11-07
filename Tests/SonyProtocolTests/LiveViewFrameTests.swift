import Foundation
import Testing

@testable import SonyProtocol

/// Live-view focus-info blocks built byte by byte (the recorded one is
/// tested in DatasetTests).
struct LiveViewFrameTests {
    /// A frame entry: type, state, priority, x, y, height, width.
    private struct Entry {
        var type: UInt16 = 6
        var state: UInt16 = 1
        var x: UInt32 = 320 * 1024
        var y: UInt32 = 240 * 1024
        var height: UInt32 = 82 * 1024
        var width: UInt32 = 98 * 1024
    }

    private static let denominators = (x: UInt32(640 * 1024), y: UInt32(480 * 1024))

    /// A focus-info block: version 0x68, padding to the first block, then
    /// blocks of `(denominators, entries)`.
    private func info(_ blocks: [(x: UInt32, y: UInt32, entries: [Entry], count: UInt16?)]) -> Data {
        var data = Data()
        func append<Integer: FixedWidthInteger>(_ value: Integer) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt16(0x68))
        data.append(contentsOf: [UInt8](repeating: 0, count: 0x28 - 2))
        for block in blocks {
            append(block.x)
            append(block.y)
            append(block.count ?? UInt16(block.entries.count))
            data.append(contentsOf: [UInt8](repeating: 0, count: 6))
            for entry in block.entries {
                append(entry.type)
                append(entry.state)
                append(UInt32(0))
                append(entry.x)
                append(entry.y)
                append(entry.height)
                append(entry.width)
            }
        }
        return data
    }

    private func block(_ entries: [Entry], count: UInt16? = nil) -> (
        x: UInt32, y: UInt32, entries: [Entry], count: UInt16?
    ) {
        (Self.denominators.x, Self.denominators.y, entries, count)
    }

    @Test func readsFocusFacesAndTracking() {
        let data = info([
            block([]), block([Entry()]), block([Entry(type: 2, state: 2)]), block([Entry(type: 2, state: 1)]),
        ])
        let frames = LiveViewFrame.parse(focusInfo: data)
        #expect(frames.map(\.kind) == [.focus, .face, .tracking])
        #expect(frames[0].centre == .centre)
        #expect(frames[0].width == 98.0 / 640)
        #expect(frames[0].height == 82.0 / 480)
        #expect(frames[1].state == .focused)
    }

    @Test func skipsABlockWithoutDenominatorsButReadsTheNext() {
        let data = info([block([]), (0, 0, [Entry()], nil), block([Entry()])])
        #expect(LiveViewFrame.parse(focusInfo: data).map(\.kind) == [.face])
    }

    @Test func keepsTheFramesBeforeATruncatedBlock() {
        var data = info([block([]), block([Entry()]), block([Entry(), Entry()])])
        data.removeLast(10)
        #expect(LiveViewFrame.parse(focusInfo: data).map(\.kind) == [.focus])
    }

    @Test func survivesACountLargerThanTheData() {
        let data = info([block([]), block([Entry()], count: 0xFFFF)])
        #expect(LiveViewFrame.parse(focusInfo: data).isEmpty)
    }

    @Test func ignoresAnOlderLayout() {
        var data = info([block([]), block([Entry()])])
        data[0] = 0x60
        #expect(LiveViewFrame.parse(focusInfo: data).isEmpty)
    }
}
