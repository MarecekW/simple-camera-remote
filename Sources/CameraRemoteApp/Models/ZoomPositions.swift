import CaptureCore
import Foundation
import Observation
import SonyProtocol
import SonyRemote

/// The camera's three zoom-and-focus presets, shown as the focal lengths
/// they hold, plus going to a typed focal length.
///
/// The camera keeps the exact lens position of each preset but doesn't say
/// what it is, so the app remembers the focal length and lens saved in each
/// slot, per camera.
@MainActor
@Observable
final class ZoomPositions {
    struct Position: Codable, Equatable {
        /// Thousandths of a millimetre, as the camera reports it.
        var focalLength: UInt32
        var lens: String?
    }

    static let slots: [UInt8] = [1, 2, 3]

    /// Saved positions of the connected camera, by slot.
    private(set) var saved: [UInt8: Position] = [:]
    /// Set while the lens moves to a position or focal length.
    private(set) var isMoving = false

    @ObservationIgnored private let messages: MessageLog
    @ObservationIgnored private var cameraKey: String?

    init(messages: MessageLog) {
        self.messages = messages
    }

    /// Loads the positions remembered for `camera`.
    func use(_ camera: SonyCamera) {
        let key = Self.defaultsKey(for: camera)
        guard key != cameraKey else { return }
        cameraKey = key
        saved = Self.load(key)
    }

    /// Whether the position in `slot` was saved with the lens now mounted.
    func fits(_ position: Position, on camera: SonyCamera) -> Bool {
        position.lens == nil || position.lens == camera.lensName
    }

    func recall(_ slot: UInt8, on camera: SonyCamera) {
        guard let position = saved[slot] else { return }
        guard fits(position, on: camera) else {
            messages.post(.warning, "Position \(slot) was saved with \(position.lens ?? "another lens").")
            return
        }
        move { try await camera.loadZoomAndFocusPreset(slot) }
    }

    /// Saves the lens' current zoom and focus in `slot`.
    func save(_ slot: UInt8, on camera: SonyCamera) {
        guard !isMoving, let focalLength = camera.focalLength, let key = cameraKey else { return }
        let position = Position(focalLength: focalLength, lens: camera.lensName)
        Task {
            do {
                try await camera.saveZoomAndFocusPreset(slot)
                // Stored for the camera it was saved on, even if another one
                // was connected meanwhile.
                if key == cameraKey { saved[slot] = position }
                persist(key == cameraKey ? saved : Self.load(key).merging([slot: position]) { $1 }, as: key)
                messages.post(.success, "Saved \(FocalLength(rawValue: focalLength)) as position \(slot).")
            } catch {
                messages.post(.failure, "The camera didn't save the position.")
                Log.ptp.error("saving zoom position failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func clear(_ slot: UInt8) {
        saved[slot] = nil
        persist()
    }

    func clearAll() {
        saved = [:]
        persist()
    }

    /// Zooms to `millimetres`, if the lens covers it.
    func go(toMillimetres millimetres: Double, on camera: SonyCamera) {
        // Compared as Double: a typed value can be far beyond UInt32.
        let target = (millimetres * 1000).rounded()
        guard let range = camera.focalLengthRange, target >= Double(range.lowerBound),
            target <= Double(range.upperBound)
        else {
            messages.post(.warning, "\(millimetres.formatted()) mm is outside the lens' range.")
            return
        }
        move { try await camera.zoom(to: UInt32(target)) }
    }

    private func move(_ action: @escaping @MainActor () async throws -> Void) {
        guard !isMoving else { return }
        isMoving = true
        Task {
            do {
                try await action()
            } catch SonyCamera.ZoomError.stalled {
                messages.post(.warning, "The lens reached the end of its range.")
            } catch {
                messages.post(.failure, "The zoom didn't respond.")
                Log.ptp.error("zoom failed: \(String(describing: error), privacy: .public)")
            }
            isMoving = false
        }
    }

    private func persist() {
        guard let cameraKey else { return }
        persist(saved, as: cameraKey)
    }

    private func persist(_ positions: [UInt8: Position], as key: String) {
        guard let data = try? JSONEncoder().encode(positions) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load(_ key: String) -> [UInt8: Position] {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([UInt8: Position].self, from: $0) } ?? [:]
    }

    private static func defaultsKey(for camera: SonyCamera) -> String {
        "camera-remote.zoomPositions.\(camera.serialNumber ?? camera.name).v1"
    }
}
