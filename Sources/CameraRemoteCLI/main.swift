// camera-remote-cli — hardware diagnostics for the Sony PTP integration.
//
// Kept deliberately small: it probes what a real camera does and helps
// diagnose problems (docs/HARDWARE_NOTES.md), not to mirror the app.

import Foundation
import SonyProtocol
import SonyRemote

let usage = """
    usage: camera-remote-cli <command> [arguments]

      props [CODE…]               print properties (all, or the given hex codes)
      dump DIR                    save the raw handshake and property datasets
      events SECONDS              log every event the camera sends
      set CODE VALUE [--force]    set a property (hex code; decimal or 0x value) to a value the
                                  camera offers now; --force sends any value
      liveview FRAMES [DIR]       fetch live-view frames, report the rate
      zoom SPEED SECONDS          run the power zoom (−8…8, as the camera allows) and report focal length
      zoom-to MM                  zoom to a focal length
      shoot DIR                   take one picture and download every file
      preset save|load SLOT       save or restore the camera's zoom and focus preset (1…3)
      frames                      print the AF frames the live view reports
      focus-at X Y                move the AF point (0…1 of the image) and focus once
      focus-step STEP COUNT       step manual focus (±1, ±3 or ±7; negative = nearer)
      magnify RATIO X Y DIR       magnify at a point, save live-view frames, then exit
      hold CODE SECONDS           hold a camera button (hex control code) down, then release it
    """

/// A parsed command line, validated before anything talks to the camera.
enum Command {
    case props([SonyPropertyCode])
    case dump(URL)
    case events(seconds: Double)
    case set(SonyPropertyCode, Int64, force: Bool)
    case liveView(frames: Int, directory: URL?)
    case zoom(speed: Int8, seconds: Double)
    case zoomTo(millimetres: Double)
    case shoot(URL)
    case preset(save: Bool, slot: UInt8)
    case frames
    case focusAt(x: Double, y: Double)
    case focusStep(Int16, count: Int)
    case magnify(ratio: Double, x: Double, y: Double, directory: URL)
    case hold(SonyControlCode, seconds: Double)

    init(_ arguments: [String]) throws(ProbeError) {
        guard let name = arguments.first else { throw ProbeError(usage) }
        let rest = Array(arguments.dropFirst())
        switch (name, rest.count) {
        case ("props", _):
            let codes = rest.compactMap(Self.parseCode)
            guard codes.count == rest.count else { throw ProbeError(usage) }
            self = .props(codes)
        case ("dump", 1):
            self = .dump(URL(fileURLWithPath: rest[0]))
        case ("events", 1):
            guard let seconds = Double(rest[0]), seconds > 0 else { throw ProbeError(usage) }
            self = .events(seconds: seconds)
        case ("set", 2...3):
            guard let code = Self.parseCode(rest[0]), let value = Self.parseNumber(rest[1]),
                rest.count == 2 || rest[2] == "--force"
            else { throw ProbeError(usage) }
            self = .set(code, value, force: rest.count == 3)
        case ("liveview", 1...2):
            guard let frames = Int(rest[0]), frames > 0 else { throw ProbeError(usage) }
            self = .liveView(frames: frames, directory: rest.count == 2 ? URL(fileURLWithPath: rest[1]) : nil)
        case ("zoom", 2):
            guard let speed = Int8(rest[0]), SonyCamera.defaultZoomSpeeds.contains(speed),
                let seconds = Double(rest[1]), seconds > 0
            else { throw ProbeError(usage) }
            self = .zoom(speed: speed, seconds: seconds)
        case ("zoom-to", 1):
            guard let millimetres = Double(rest[0]), millimetres > 0, millimetres < 1_000_000 else {
                throw ProbeError(usage)
            }
            self = .zoomTo(millimetres: millimetres)
        case ("shoot", 1):
            self = .shoot(URL(fileURLWithPath: rest[0]))
        case ("preset", 2):
            guard let slot = UInt8(rest[1]), SonyCamera.zoomAndFocusPresetSlots.contains(slot) else {
                throw ProbeError(usage)
            }
            switch rest[0] {
            case "save": self = .preset(save: true, slot: slot)
            case "load": self = .preset(save: false, slot: slot)
            default: throw ProbeError(usage)
            }
        case ("frames", 0):
            self = .frames
        case ("focus-at", 2):
            guard let x = Self.parseFraction(rest[0]), let y = Self.parseFraction(rest[1]) else {
                throw ProbeError(usage)
            }
            self = .focusAt(x: x, y: y)
        case ("focus-step", 2):
            guard let step = Int16(rest[0]), SonyCamera.isManualFocusStep(step),
                let count = Int(rest[1]), count > 0
            else { throw ProbeError(usage) }
            self = .focusStep(step, count: count)
        case ("hold", 2):
            let digits = rest[0].hasPrefix("0x") ? String(rest[0].dropFirst(2)) : rest[0]
            guard let code = UInt16(digits, radix: 16), let seconds = Double(rest[1]), seconds > 0 else {
                throw ProbeError(usage)
            }
            self = .hold(SonyControlCode(rawValue: code), seconds: seconds)
        case ("magnify", 4):
            guard let ratio = Double(rest[0]), ratio > 1, let x = Self.parseFraction(rest[1]),
                let y = Self.parseFraction(rest[2])
            else { throw ProbeError(usage) }
            self = .magnify(ratio: ratio, x: x, y: y, directory: URL(fileURLWithPath: rest[3]))
        default:
            throw ProbeError(usage)
        }
    }

    /// A position across the image, 0…1.
    private static func parseFraction(_ text: String) -> Double? {
        Double(text).flatMap { (0...1).contains($0) ? $0 : nil }
    }

    /// A hex property code, with or without `0x`.
    private static func parseCode(_ text: String) -> SonyPropertyCode? {
        let digits = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt16(digits, radix: 16).map(SonyPropertyCode.init(rawValue:))
    }

    /// A decimal value, or hex with `0x`.
    private static func parseNumber(_ text: String) -> Int64? {
        text.hasPrefix("0x") ? Int64(text.dropFirst(2), radix: 16) : Int64(text)
    }
}

@MainActor
func run(_ command: Command) async throws {
    let browser = CameraBrowser()
    browser.start()
    guard let device = await browser.firstCamera(timeout: .seconds(10)) else {
        throw ProbeError("no Sony camera found — is it on, connected over USB and in PC Remote mode?")
    }
    let probe = Probe(camera: SonyCamera(device: device))
    defer { probe.disconnect() }
    try await probe.connect()

    switch command {
    case .props(let codes): probe.printProperties(codes)
    case .dump(let directory): try await probe.dump(to: directory)
    case .events(let seconds): try await Task.sleep(for: .seconds(seconds))
    case .set(let code, let value, let force): try await probe.set(code, to: value, force: force)
    case .liveView(let frames, let directory): try await probe.measureLiveView(frames: frames, saveTo: directory)
    case .zoom(let speed, let seconds): try await probe.zoom(speed: speed, for: seconds)
    case .zoomTo(let millimetres): try await probe.zoom(toMillimetres: millimetres)
    case .shoot(let directory): try await probe.shoot(into: directory)
    case .preset(let save, let slot): try await probe.preset(save: save, slot: slot)
    case .frames: try await probe.printFrames()
    case .focusAt(let x, let y): try await probe.focus(atX: x, y: y)
    case .focusStep(let step, let count): try await probe.stepFocus(step, count: count)
    case .hold(let control, let seconds): try await probe.hold(control, for: seconds)
    case .magnify(let ratio, let x, let y, let directory):
        try await probe.magnify(ratio, atX: x, y: y, saveTo: directory)
    }
}

// ImageCaptureCore delivers its callbacks through the main run loop, so the
// work runs in a task while the main thread services the run loop.
Task { @MainActor in
    do {
        try await run(try Command(Array(CommandLine.arguments.dropFirst())))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
