import CaptureCore
import Foundation
import Testing

struct PresetTests {
    private static func preset(named name: String = "Studio-1-Product") -> Preset {
        var guides = Guides()
        guides.add(.horizontal, at: 0.25)
        return Preset(
            name: name, camera: "ILCE-6700", savedAt: Date(timeIntervalSince1970: 1_800_000_000),
            settings: [
                .init(code: 0x500E, value: .unsigned(1), display: "M"),
                .init(code: 0x5010, value: .signed(-300), display: "−0.3"),
            ],
            afPoint: .init(x: 0.4, y: 0.6),
            view: .init(
                showsGrid: true, showsCrosshair: false, showsRulers: true, guides: guides,
                overlayPath: "/tmp/overlay.jpg", showsOverlay: true, overlayOpacity: 0.4))
    }

    private static func temporaryLibrary() -> PresetLibrary {
        PresetLibrary(folder: FileManager.default.temporaryDirectory.appending(path: "presets-\(UUID().uuidString)"))
    }

    @Test func writesReadableCodesAndValues() throws {
        let data = try JSONEncoder().encode(Self.preset())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#""code":"0x500E""#))
        #expect(text.contains(#""value":"0x1""#))
        #expect(text.contains(#""value":"-300""#))
    }

    @Test func recallsOnlyTheSettingsAPresetKeepsInTheirOrder() {
        var preset = Self.preset()
        preset.settings = [
            .init(code: 0x5010, value: .signed(-300), display: ""),
            .init(code: 0x5013, value: .unsigned(0x10002), display: ""),  // added by hand
            .init(code: 0x500E, value: .unsigned(1), display: ""),
            .init(code: 0x5010, value: .signed(700), display: ""),  // repeated: the first counts
        ]
        let (recalled, ignored) = preset.settings(limitedTo: [0x500E, 0x5007, 0x5010])
        #expect(recalled.map(\.code) == [0x500E, 0x5010])
        #expect(recalled.map(\.value) == [.unsigned(1), .signed(-300)])
        #expect(ignored == [0x5013])
    }

    @Test func survivesSavingAndLoading() throws {
        let library = Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.folder) }
        let preset = Self.preset()
        try library.save(preset)
        let loaded = library.load()
        #expect(loaded.presets == [preset])
        #expect(loaded.unreadable.isEmpty)
    }

    @Test func sortsByNameAndReportsUnreadableFiles() throws {
        let library = Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.folder) }
        try library.save(Self.preset(named: "Studio-10"))
        try library.save(Self.preset(named: "Studio-2"))
        try Data("not json".utf8).write(to: library.file(for: "Broken"))
        let loaded = library.load()
        #expect(loaded.presets.map(\.name) == ["Studio-2", "Studio-10"])
        #expect(loaded.unreadable == ["Broken.json"])
    }

    @Test func takesTheNameFromTheFile() throws {
        let library = Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.folder) }
        try library.save(Self.preset(named: "Studio"))
        try FileManager.default.copyItem(at: library.file(for: "Studio"), to: library.file(for: "Studio copy"))
        #expect(library.load().presets.map(\.name) == ["Studio", "Studio copy"])
    }

    @Test func refusesAFileFromANewerVersion() throws {
        let data = try JSONEncoder().encode(Self.preset())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = Preset.currentVersion + 1
        let newer = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Preset.self, from: newer) }
    }

    @Test func renamesThePresetAndItsFile() throws {
        let library = Self.temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.folder) }
        try library.save(Self.preset(named: "Old"))
        try library.rename("Old", to: "New")
        #expect(library.load().presets.map(\.name) == ["New"])
        try library.rename("New", to: "new")
        #expect(library.load().presets.map(\.name) == ["new"])
    }

    @Test func checksNames() {
        #expect(PresetLibrary.problem(with: "  ", existing: []) == .empty)
        #expect(PresetLibrary.problem(with: "a/b", existing: []) == .invalidCharacters)
        #expect(PresetLibrary.problem(with: "a:b", existing: []) == .invalidCharacters)
        #expect(PresetLibrary.problem(with: ".hidden", existing: []) == .invalidCharacters)
        #expect(PresetLibrary.problem(with: "studio", existing: ["Studio"]) == .taken)
        #expect(PresetLibrary.problem(with: "Studio-1-Product", existing: ["Studio"]) == nil)
    }
}
