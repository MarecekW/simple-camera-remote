import Foundation
import ImageIO
import SonyProtocol
import SonyRemote

/// The CLI's commands, run against a connected camera while logging every
/// event it sends.
@MainActor
final class Probe {
    private let camera: SonyCamera
    private let start = ContinuousClock.now
    private var eventTask: Task<Void, Never>?

    init(camera: SonyCamera) {
        self.camera = camera
    }

    // MARK: - Connection

    func connect() async throws {
        let events = camera.transport.subscribeToEvents()
        eventTask = Task { [weak self] in
            for await event in events {
                self?.log("event \(event.code) \(event.parameters.map { String(format: "0x%X", $0) })")
            }
        }
        try await camera.connect()
        let info = camera.deviceInfo.map {
            "protocol \($0.protocolVersion), \($0.propertyCodes.count) properties, \($0.controlCodes.count) controls"
        }
        log("connected to \(camera.name): \(info ?? "")")
    }

    func disconnect() {
        eventTask?.cancel()
        camera.disconnect()
    }

    // MARK: - Commands

    func printProperties(_ codes: [SonyPropertyCode]) {
        let selected = codes.isEmpty ? camera.properties.keys.sorted { $0.rawValue < $1.rawValue } : codes
        for code in selected {
            guard let descriptor = camera.properties[code] else {
                print("\(code): not reported")
                continue
            }
            print(Self.describe(descriptor))
        }
    }

    func dump(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let info = try await camera.fetchExtendedDeviceInfo()
        try info.write(to: directory.appending(path: "ext-device-info.bin"))
        let properties = try await camera.fetchPropertyDataset()
        try properties.write(to: directory.appending(path: "all-properties.bin"))
        log("saved \(info.count) + \(properties.count) bytes to \(directory.path)")
    }

    /// Sets `code` to `value` only if the camera offers it now, unless
    /// `force`d: an unsupported value once crashed the A6700.
    func set(_ code: SonyPropertyCode, to value: Int64, force: Bool) async throws {
        if let before = camera.properties[code] { print("before: " + Self.describe(before)) }
        let encoded = value < 0 ? PTPValue.signed(value) : .unsigned(UInt64(value))
        guard force || camera.properties[code]?.accepts(encoded) == true else {
            throw ProbeError(
                "the camera doesn't offer \(Self.format(encoded)) for \(code) now; --force sends it anyway")
        }
        try await camera.setProperty(code, to: encoded)
        // The camera applies the change asynchronously.
        try await Task.sleep(for: .seconds(1))
        try await camera.refreshProperties()
        if let after = camera.properties[code] { print("after:  " + Self.describe(after)) }
    }

    func measureLiveView(frames: Int, saveTo directory: URL?) async throws {
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let begin = ContinuousClock.now
        var received = 0
        var notReady = 0
        var bytes = 0
        while received < frames {
            guard let image = try await camera.liveViewImage() else {
                notReady += 1
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            received += 1
            bytes += image.jpegData.count
            if received == 1 || received == frames {
                log("frame \(received): \(image.jpegData.count) bytes, \(Self.pixelSize(of: image.jpegData))")
                try directory.map { try image.jpegData.write(to: $0.appending(path: "liveview-\(received).jpg")) }
            }
        }
        let seconds = Self.seconds(ContinuousClock.now - begin)
        let rate = String(format: "%.1f", Double(received) / seconds)
        log(
            "\(received) frames in \(String(format: "%.2f", seconds)) s = \(rate) fps, "
                + "avg \(bytes / received / 1024) KB, \(notReady) not-ready answers")
    }

    func printFrames(_ label: String = "frames") async throws {
        let image = try await nextLiveViewImage()
        log("\(label): \(Self.pixelSize(of: image.jpegData)), \(image.frames.count) frame(s)")
        for frame in image.frames {
            log(
                String(
                    format: "  %@ type %d state %d centre (%.1f, %.1f) size %.1f × %.1f  [640×480 grid]",
                    "\(frame.kind)", frame.type, frame.state.rawValue, frame.centre.x * 640, frame.centre.y * 480,
                    frame.width * 640, frame.height * 480))
        }
    }

    func focus(atX x: Double, y: Double) async throws {
        let area = camera.properties[.focusArea].map { Self.format($0.currentValue) } ?? "?"
        let mode = camera.properties[.focusMode].map { Self.format($0.currentValue) } ?? "?"
        log("focus area \(area), focus mode \(mode)")
        try await printFrames("before")
        try await camera.moveAFPoint(to: .init(x: x, y: y))
        try await Task.sleep(for: .milliseconds(400))
        try await printFrames("after moving")
        let begin = ContinuousClock.now
        let result = try await camera.focusOnce()
        log("focus: \(result) in \(String(format: "%.2f", Self.seconds(ContinuousClock.now - begin))) s")
        try await printFrames("after focusing")
    }

    func magnify(_ ratio: Double, atX x: Double, y: Double, saveTo directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log("magnifier ratios \(camera.magnifierRatios), now \(camera.magnification.map { "×\($0)" } ?? "off")")
        try await nextLiveViewImage().jpegData.write(to: directory.appending(path: "before.jpg"))
        try await camera.magnify(ratio, at: .init(x: x, y: y))
        try await Task.sleep(for: .milliseconds(800))
        try await camera.refreshProperties()
        let value = camera.properties[.focusMagnifier].map { Self.format($0.currentValue) } ?? "?"
        log("magnifier now \(value)")
        try await printFrames("magnified")
        try await nextLiveViewImage().jpegData.write(to: directory.appending(path: "magnified.jpg"))
        try await camera.endMagnification()
        try await Task.sleep(for: .milliseconds(500))
        try await camera.refreshProperties()
        log("after exit: \(camera.magnification.map { "×\($0)" } ?? "off")")
    }

    func hold(_ control: SonyControlCode, for seconds: Double) async throws {
        let mode = camera.properties[.focusMode].map { Self.format($0.currentValue) } ?? "?"
        log("focus mode \(mode); pressing \(control)")
        try await camera.press(control)
        let end = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(250))
            try await camera.refreshProperties()
            let indication = camera.properties[.focusIndication].map { Self.format($0.currentValue) } ?? "?"
            let mode = camera.properties[.focusMode].map { Self.format($0.currentValue) } ?? "?"
            log("  focus indication \(indication), focus mode \(mode)")
        }
        try await camera.release(control)
        log("released")
    }

    func stepFocus(_ step: Int16, count: Int) async throws {
        for index in 1...count {
            try await camera.stepFocus(step)
            log("step \(index) of \(step): ok")
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func nextLiveViewImage() async throws -> LiveViewImage {
        while true {
            if let image = try await camera.liveViewImage() { return image }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func zoom(speed: Int8, for seconds: Double) async throws {
        log("focal length before: \(focalLength)")
        // Refuses a speed outside the camera's range, and zooming while the
        // camera doesn't allow it.
        try await camera.startZoom(speed: speed)
        do {
            let end = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < end {
                try await Task.sleep(for: .milliseconds(250))
                try await camera.refreshProperties()
                log("focal length: \(focalLength)")
            }
        } catch {
            // Never leave the lens driving.
            try? await camera.stopZoom()
            throw error
        }
        try await camera.stopZoom()
        try await Task.sleep(for: .seconds(1))
        try await camera.refreshProperties()
        log("focal length after stop: \(focalLength)")
    }

    func zoom(toMillimetres millimetres: Double) async throws {
        log("focal length before: \(focalLength)")
        let begin = ContinuousClock.now
        let reached = try await camera.zoom(to: UInt32((millimetres * 1000).rounded()))
        log("reached \(Double(reached) / 1000) mm in \(Self.seconds(ContinuousClock.now - begin)) s")
        try await Task.sleep(for: .seconds(1.5))
        try await camera.refreshProperties()
        log("settled at: \(focalLength)")
    }

    func preset(save: Bool, slot: UInt8) async throws {
        log("focal length before: \(focalLength)")
        if save {
            try await camera.saveZoomAndFocusPreset(slot)
        } else {
            try await camera.loadZoomAndFocusPreset(slot)
        }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(500))
            try await camera.refreshProperties()
            log("focal length: \(focalLength)")
        }
    }

    /// Takes one picture and downloads every file it produced.  Expects one
    /// file per format the settings ask for (RAW+JPEG = 2).
    func shoot(into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        printProperties([
            .stillImageStoreDestination, .pcSaveImage, .pcSaveImageSize, .fileFormat, .focusMode,
            .mediaSlot1Status, .mediaSlot1RemainingShots, .objectsInMemory,
        ])
        let expectedFiles = camera.properties[.pcSaveImage]?.currentValue == .unsigned(1) ? 2 : 1

        log("shutter")
        try await camera.press(.shutterHalfPress)
        do {
            try await camera.press(.shutterFullPress)
            try await Task.sleep(for: .milliseconds(100))
            try await camera.release(.shutterFullPress)
        } catch {
            // Never leave the shutter half-pressed.
            try? await camera.release(.shutterHalfPress)
            throw error
        }
        try await camera.release(.shutterHalfPress)

        let deadline = ContinuousClock.now + .seconds(30)
        var downloaded = 0
        while downloaded < expectedFiles {
            guard let file = try await camera.downloadCapturedImage() else {
                guard ContinuousClock.now < deadline else {
                    throw ProbeError("only \(downloaded) of \(expectedFiles) files arrived within 30 s")
                }
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            downloaded += 1
            let url = try Self.destination(for: file.info.filename, in: directory)
            try file.data.write(to: url, options: .withoutOverwriting)
            log(
                "downloaded \(url.lastPathComponent): \(file.data.count / 1024) KB, "
                    + "format \(String(format: "0x%04X", file.info.format))")
        }
    }

    // MARK: - Helpers

    private var focalLength: String {
        guard let value = camera.properties[.focalLength]?.currentValue.integerValue else { return "—" }
        return String(format: "%.1f mm", Double(value) / 1000)
    }

    /// The camera names the file; keep only a plain file name so it can't
    /// point anywhere else.
    private static func destination(for cameraFilename: String, in directory: URL) throws -> URL {
        let name = URL(fileURLWithPath: cameraFilename).lastPathComponent
        guard !name.isEmpty, name != "/", !name.hasPrefix(".") else {
            throw ProbeError("camera sent an unusable filename: \(cameraFilename)")
        }
        return directory.appending(path: name)
    }

    private func log(_ message: String) {
        print("[\(String(format: "%7.3f", Self.seconds(ContinuousClock.now - start)))] " + message)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func describe(_ descriptor: PropertyDescriptor) -> String {
        var line = "\(descriptor.code) [\(descriptor.dataType), \(descriptor.availability)"
        line += descriptor.isWritable ? ", writable] = " : "] = "
        line += format(descriptor.currentValue)
        switch descriptor.constraint {
        case .none: break
        case .range(let minimum, let maximum, let step):
            line += "  range \(format(minimum))…\(format(maximum)) step \(format(step))"
        case .enumeration(let settable, let supported):
            let shown = supported.prefix(12).map(format).joined(separator: " ")
            line += "  settable \(settable.count)/\(supported.count): \(shown)\(supported.count > 12 ? " …" : "")"
        }
        return line
    }

    private static func format(_ value: PTPValue) -> String {
        switch value {
        case .signed(let number): "\(number)"
        case .unsigned(let number): String(format: "0x%llX", number)
        case .string(let text): "\"\(text)\""
        }
    }

    private static func pixelSize(of jpeg: Data) -> String {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return "undecodable" }
        return "\(width)×\(height)"
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
