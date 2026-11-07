import CaptureCore
import Foundation
import Testing

struct GuidesTests {
    @Test func dragsAGuideOutAndKeepsItOnTheImage() {
        var guides = Guides()
        let id = guides.add(.horizontal, at: -0.02)
        guides.move(id, to: 0.4)
        guides.finishDragging(id)
        #expect(guides.all.map(\.position) == [0.4])
        #expect(guides.all.first?.axis == .horizontal)
    }

    @Test func removesAGuideLetGoOffTheImage() {
        var guides = Guides()
        let kept = guides.add(.vertical, at: 0.5)
        let dropped = guides.add(.vertical, at: 0.7)
        guides.move(dropped, to: 1.03)
        guides.finishDragging(dropped)
        #expect(guides.all.map(\.id) == [kept])
    }

    @Test func survivesSavingAndLoading() throws {
        var guides = Guides()
        guides.add(.horizontal, at: 0.25)
        guides.add(.vertical, at: 0.75)
        let loaded = try JSONDecoder().decode(Guides.self, from: JSONEncoder().encode(guides))
        #expect(loaded == guides)
    }

    @Test func dropsGuidesLeftOffTheImage() {
        var guides = Guides()
        guides.add(.horizontal, at: -0.02)
        guides.add(.vertical, at: 0.3)
        guides.removeOffImage()
        #expect(guides.all.map(\.position) == [0.3])
    }
}
