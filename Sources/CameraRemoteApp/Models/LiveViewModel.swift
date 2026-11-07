import AppKit
import CaptureCore
import ImageIO
import Observation
import SonyProtocol
import SonyRemote

/// The live view: pulls frames from the camera as fast as it delivers them
/// (~30 fps), decodes them off the main actor, and holds the view options,
/// which it remembers between launches.
@MainActor
@Observable
final class LiveViewModel {
    /// The newest decoded frame.
    private(set) var image: CGImage?
    /// Focus peaking for `image`, when shown.
    private(set) var peakingMarks: CGImage?
    /// The frame size, changed only when it does, so views that need just the
    /// shape don't re-render for every frame.
    private(set) var imageSize: CGSize?
    /// Sampled a few times a second and eased towards each sample on every
    /// frame: it moves smoothly but calmly.
    private(set) var histogram: Histogram?
    @ObservationIgnored private var histogramSmoother = HistogramSmoother()
    @ObservationIgnored private var histogramSampledAt: ContinuousClock.Instant?
    @ObservationIgnored private var histogramSteppedAt: ContinuousClock.Instant?
    private static let histogramInterval: Duration = .milliseconds(300)
    /// How soon to ask again when the camera has no new frame yet (it
    /// streams about 30 a second).
    private static let frameRetryDelay: Duration = .milliseconds(10)
    /// How long to wait after a failed frame, so a busy camera isn't flooded.
    private static let errorRetryDelay: Duration = .milliseconds(100)

    /// Whether this frame should be counted for the histogram.
    private var needsHistogram: Bool {
        guard showsHistogram else { return false }
        guard let histogramSampledAt else { return true }
        return ContinuousClock.now - histogramSampledAt >= Self.histogramInterval
    }
    /// The AF frames, faces and tracked subjects the camera reports, changed
    /// only when they do (not every frame).
    private(set) var cameraFrames: [LiveViewFrame] = []
    /// Frames shown per second, averaged over a few seconds and updated once
    /// a second, so the readout holds steady instead of flickering 30/31.
    private(set) var framesPerSecond = 0

    var showsGrid: Bool {
        didSet { UserDefaults.standard.set(showsGrid, forKey: Keys.showsGrid) }
    }
    var showsCrosshair: Bool {
        didSet { UserDefaults.standard.set(showsCrosshair, forKey: Keys.showsCrosshair) }
    }
    var showsHistogram: Bool {
        didSet {
            UserDefaults.standard.set(showsHistogram, forKey: Keys.showsHistogram)
            // Shown again, it starts from the scene then, not an old one.
            if !showsHistogram { resetHistogram() }
        }
    }
    /// Rulers along the live view, with the guides dragged out of them.
    var showsRulers: Bool {
        didSet { UserDefaults.standard.set(showsRulers, forKey: Keys.showsRulers) }
    }
    /// In-focus detail marked green (`FocusPeaking`).
    var showsPeaking: Bool {
        didSet {
            UserDefaults.standard.set(showsPeaking, forKey: Keys.showsPeaking)
            if !showsPeaking { peakingMarks = nil }
        }
    }
    var peakingSensitivity: FocusPeaking.Sensitivity {
        didSet { UserDefaults.standard.set(peakingSensitivity.rawValue, forKey: Keys.peakingSensitivity) }
    }
    /// Changed through the guide methods below, which save it when a drag
    /// ends rather than on every movement.
    private(set) var guides: Guides
    @ObservationIgnored private var guideFromRuler: UUID?

    /// A reference image laid over the live view, so each sample is placed
    /// the same way.
    private(set) var overlayImage: CGImage?
    /// The overlay image's file.
    private(set) var overlayURL: URL?
    var overlayName: String? { overlayURL?.lastPathComponent }
    var showsOverlay: Bool {
        didSet { UserDefaults.standard.set(showsOverlay, forKey: Keys.showsOverlay) }
    }
    var overlayOpacity: Double {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: Keys.overlayOpacity) }
    }

    @ObservationIgnored private var frameRate = FrameRateMeter()

    /// Overlays are scaled to this many pixels on the long side: plenty for
    /// a ~1000 px live view, without holding a 26 MP image in memory.
    nonisolated private static let overlayMaximumPixels = 2048

    private enum Keys {
        static let showsGrid = "camera-remote.liveView.showsGrid.v1"
        static let showsCrosshair = "camera-remote.liveView.showsCrosshair.v1"
        static let showsHistogram = "camera-remote.liveView.showsHistogram.v1"
        static let showsOverlay = "camera-remote.liveView.showsOverlay.v1"
        static let overlayOpacity = "camera-remote.liveView.overlayOpacity.v1"
        static let overlayPath = "camera-remote.liveView.overlayPath.v1"
        static let showsRulers = "camera-remote.liveView.showsRulers.v1"
        static let showsPeaking = "camera-remote.liveView.showsPeaking.v1"
        static let peakingSensitivity = "camera-remote.liveView.peakingSensitivity.v1"
        static let guides = "camera-remote.liveView.guides.v1"
    }

    init() {
        let defaults = UserDefaults.standard
        showsGrid = defaults.bool(forKey: Keys.showsGrid)
        showsCrosshair = defaults.bool(forKey: Keys.showsCrosshair)
        showsHistogram = defaults.object(forKey: Keys.showsHistogram) as? Bool ?? true
        showsRulers = defaults.bool(forKey: Keys.showsRulers)
        showsPeaking = defaults.bool(forKey: Keys.showsPeaking)
        peakingSensitivity =
            defaults.string(forKey: Keys.peakingSensitivity).flatMap(FocusPeaking.Sensitivity.init(rawValue:))
            ?? .medium
        var guides =
            defaults.data(forKey: Keys.guides).flatMap { try? JSONDecoder().decode(Guides.self, from: $0) } ?? Guides()
        guides.removeOffImage()
        self.guides = guides
        showsOverlay = defaults.object(forKey: Keys.showsOverlay) as? Bool ?? true
        overlayOpacity = defaults.object(forKey: Keys.overlayOpacity) as? Double ?? 0.4
        if let path = defaults.string(forKey: Keys.overlayPath) {
            Task { await restoreOverlay(from: URL(fileURLWithPath: path)) }
        }
    }

    // MARK: - Streaming

    /// Streams until the calling task is cancelled or the camera's session
    /// ends.  Errors that leave the session up (the camera busy mid-capture,
    /// an unreadable frame) are logged and retried.
    func run(_ camera: SonyCamera) async {
        defer { clearFrame() }
        while !Task.isCancelled, camera.isConnected {
            do {
                guard let liveImage = try await camera.liveViewImage() else {
                    // Between frames the camera answers "not ready".
                    updateFrameRate()
                    try await Task.sleep(for: Self.frameRetryDelay)
                    continue
                }
                let frame = await Self.decode(
                    liveImage.jpegData, withHistogram: needsHistogram,
                    peaking: showsPeaking ? FocusPeaking(sensitivity: peakingSensitivity) : nil)
                try Task.checkCancellation()
                if let frame { show(frame) }
                if cameraFrames != liveImage.frames { cameraFrames = liveImage.frames }
            } catch is CancellationError {
                return
            } catch {
                guard camera.isConnected else { return }
                Log.liveView.error("live view frame failed: \(String(describing: error), privacy: .public)")
                updateFrameRate()
                try? await Task.sleep(for: Self.errorRetryDelay)
            }
        }
    }

    private func show(_ frame: DecodedFrame) {
        image = frame.image
        // Turned off while the frame was decoding: stays off.
        peakingMarks = showsPeaking ? frame.peakingMarks : nil
        if let sample = frame.histogram {
            histogramSmoother.setTarget(sample)
            histogramSampledAt = .now
        }
        if showsHistogram {
            let now = ContinuousClock.now
            histogram = histogramSmoother.step(after: histogramSteppedAt.map { now - $0 } ?? .zero)
            histogramSteppedAt = now
        }
        let size = CGSize(width: frame.image.width, height: frame.image.height)
        if imageSize != size { imageSize = size }
        frameRate.frame(at: .now)
        publishFrameRate()
    }

    private func updateFrameRate() {
        frameRate.update(at: .now)
        publishFrameRate()
    }

    private func publishFrameRate() {
        if framesPerSecond != frameRate.framesPerSecond { framesPerSecond = frameRate.framesPerSecond }
    }

    private func resetHistogram() {
        histogram = nil
        histogramSmoother.reset()
        histogramSampledAt = nil
        histogramSteppedAt = nil
    }

    private func clearFrame() {
        image = nil
        peakingMarks = nil
        imageSize = nil
        resetHistogram()
        frameRate.reset()
        cameraFrames = []
        framesPerSecond = 0
    }

    private struct DecodedFrame {
        let image: CGImage
        let histogram: Histogram?
        let peakingMarks: CGImage?
    }

    /// Decodes on a background thread; `ShouldCacheImmediately` makes the
    /// decode happen here, not lazily on the main thread at draw time.
    /// Peaking, when asked for, is worked out here too, so the marks and
    /// the frame they belong to are shown together.
    @concurrent
    private static func decode(_ jpeg: Data, withHistogram: Bool, peaking: FocusPeaking?) async -> DecodedFrame? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return DecodedFrame(
            image: image, histogram: withHistogram ? Histogram(image: image) : nil,
            peakingMarks: peaking?.marks(for: image))
    }

    // MARK: - Guides

    /// A guide being dragged out of a ruler; guides another drag left off
    /// the image go first.
    func beginGuide(_ axis: Guides.Guide.Axis, at position: Double) -> UUID {
        guides.removeOffImage()
        let id = guides.add(axis, at: position)
        guideFromRuler = id
        return id
    }

    /// Ends the drag out of a ruler.
    func endGuideFromRuler() {
        guard let guideFromRuler else { return }
        self.guideFromRuler = nil
        endGuide(guideFromRuler)
    }

    func moveGuide(_ id: UUID, to position: Double) {
        guides.move(id, to: position)
    }

    /// A drag let go: off the image the guide goes; either way the guides
    /// are saved.
    func endGuide(_ id: UUID) {
        guides.finishDragging(id)
        saveGuides()
    }

    func clearGuides() {
        guides.removeAll()
        saveGuides()
    }

    private func saveGuides() {
        if let data = try? JSONEncoder().encode(guides) { UserDefaults.standard.set(data, forKey: Keys.guides) }
    }

    // MARK: - Presets

    /// The layout a preset keeps.
    var presetView: Preset.View {
        Preset.View(
            showsGrid: showsGrid, showsCrosshair: showsCrosshair, showsRulers: showsRulers, guides: guides,
            overlayPath: overlayURL?.path, showsOverlay: showsOverlay, overlayOpacity: overlayOpacity)
    }

    /// Lays the live view out as `view` says; returns false if its overlay
    /// image can't be read any more (the rest is applied).
    func apply(_ view: Preset.View) async -> Bool {
        showsGrid = view.showsGrid
        showsCrosshair = view.showsCrosshair
        showsRulers = view.showsRulers
        guides = view.guides
        saveGuides()
        overlayOpacity = view.overlayOpacity
        var isOverlayRead = true
        if let path = view.overlayPath {
            let url = URL(fileURLWithPath: path)
            if url != overlayURL {
                isOverlayRead = await chooseOverlay(url)
                // Not the old overlay under the new preset's name.
                if !isOverlayRead { clearOverlay() }
            }
        } else {
            clearOverlay()
        }
        showsOverlay = view.showsOverlay
        return isOverlayRead
    }

    // MARK: - Overlay

    /// Uses the image at `url` as the overlay and shows it; returns false if
    /// it can't be read.
    func chooseOverlay(_ url: URL) async -> Bool {
        guard let image = await Self.readOverlay(url) else { return false }
        setOverlay(image, from: url)
        showsOverlay = true
        return true
    }

    func clearOverlay() {
        overlayImage = nil
        overlayURL = nil
        UserDefaults.standard.removeObject(forKey: Keys.overlayPath)
    }

    /// The overlay remembered from the last launch, keeping its saved
    /// visibility; forgotten if the file is gone.
    private func restoreOverlay(from url: URL) async {
        guard let image = await Self.readOverlay(url) else {
            Log.liveView.notice("overlay \(url.path, privacy: .public) can't be read any more; forgetting it")
            clearOverlay()
            return
        }
        setOverlay(image, from: url)
    }

    private func setOverlay(_ image: CGImage, from url: URL) {
        overlayImage = image
        overlayURL = url
        UserDefaults.standard.set(url.path, forKey: Keys.overlayPath)
    }

    /// A downscaled copy, in the image's stored orientation: the live view
    /// is in sensor orientation too.
    @concurrent
    private static func readOverlay(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: overlayMaximumPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
