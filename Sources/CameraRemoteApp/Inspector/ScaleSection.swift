import CaptureCore
import SonyProtocol
import SonyRemote
import SwiftUI

/// The scale estimate: from the working distance and the live focal length,
/// how many pixels per millimetre the subject gets and whether the smallest
/// feature (a knot) has enough of them in the full-resolution image.  Beside
/// it, the scale measured in review, when there is one.
struct ScaleSection: View {
    let camera: SonyCamera
    @Bindable var settings: AppSettings
    let capture: CaptureModel

    @State private var distanceText = ""
    @FocusState private var isDistanceFocused: Bool

    var body: some View {
        InspectorSection("Scale", id: "scale", summary: summary, expandedByDefault: false) {
            InspectorRow("Distance") {
                HStack(spacing: Layout.cellGap) {
                    TextField("e.g. 450", text: $distanceText)
                        .textFieldStyle(.plain)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, Layout.valueInset)
                        .panelBox(fill: Theme.background)
                        .focused($isDistanceFocused)
                        .onSubmit { isDistanceFocused = false }
                    Text("mm").foregroundStyle(Theme.textSecondary)
                }
                .help("From the ⦵ mark on the camera's top plate (the sensor plane) to the subject")
            }
            if let estimate {
                InspectorRow("Estimate") {
                    InspectorValue(Self.pixelsPerMillimetre(estimate.pixelsPerMillimetre))
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .help("Estimated from the focal length and the distance")
                }
                InspectorRow("Field") {
                    InspectorValue(
                        "\(Self.millimetres(estimate.fieldOfView.width)) × \(Self.millimetres(estimate.fieldOfView.height)) mm"
                    )
                    .font(.callout.monospacedDigit())
                    .help("The subject area the full 3:2 frame covers")
                }
                InspectorRow("Feature", advisory: featureAdvisory(estimate)) {
                    InspectorValue(featureText(estimate))
                        .font(.callout.monospacedDigit())
                        .help(
                            "How many pixels the smallest feature gets in the full-resolution image (Settings › Checks › Scale estimate)"
                        )
                }
            } else {
                InspectorRow("") {
                    InspectorValue(
                        settings.scaleDistance == nil ? "Enter the working distance." : "Too close to focus."
                    )
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            if let measured = capture.session.measuredScale {
                if let focalLength = measured.focalLength, measured.isStale(atFocalLength: camera.focalLength) {
                    // The zoom has moved: captures don't record it now.
                    InspectorRow("Measured", advisory: staleNote(focalLength)) {
                        InspectorValue("Measured at \(FocalLength(rawValue: focalLength)) — measure again")
                    }
                } else {
                    InspectorRow("Measured") {
                        InspectorValue(Self.pixelsPerMillimetre(measured.pixelsPerMillimetre))
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .help(
                                "Measured on \(measured.capture): \(Int(measured.pixels.rounded())) px over "
                                    + "\(measured.millimetres.formatted()) mm. Recorded with every later capture of "
                                    + "this session at this focal length; measure again in review (Measure) after "
                                    + "changing the distance.")
                    }
                }
            }
        } menu: {
            Button("Clear Measured Scale") { capture.setMeasuredScale(nil) }
                .disabled(capture.session.measuredScale == nil || capture.isCapturing)
        }
        .onAppear { distanceText = settings.scaleDistance.map(Self.editableMillimetres) ?? "" }
        .onChange(of: isDistanceFocused) { _, focused in
            capture.isEditingText = focused
            if !focused { applyDistance() }
        }
        .onDisappear { capture.isEditingText = false }
    }

    private var estimate: ResolutionEstimate? {
        ResolutionEstimate(camera: camera, settings: settings)
    }

    /// The estimate, or the measurement without one (while it holds).
    private var summary: Text? {
        let measured = capture.session.measuredScale.flatMap {
            $0.isStale(atFocalLength: camera.focalLength) ? nil : $0
        }
        return (estimate?.pixelsPerMillimetre ?? measured?.pixelsPerMillimetre)
            .map { Text(Self.pixelsPerMillimetre($0)) }
    }

    private func staleNote(_ focalLength: UInt32) -> String {
        "The scale was measured at \(FocalLength(rawValue: focalLength)); at this focal length it doesn't hold, so "
            + "captures don't record it. Measure again in review (Measure), or zoom back."
    }

    /// "12.3 px/mm".
    private static func pixelsPerMillimetre(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " px/mm"
    }

    /// "2 mm → 49 px".
    private func featureText(_ estimate: ResolutionEstimate) -> String {
        "\(settings.featureSize.formatted()) mm → \(Int(estimate.pixels(forFeature: settings.featureSize).rounded())) px"
    }

    /// Too few pixels for the feature, and what distance would give enough
    /// at this focal length.
    private func featureAdvisory(_ estimate: ResolutionEstimate) -> String? {
        let pixels = estimate.pixels(forFeature: settings.featureSize)
        guard pixels < settings.featureMinimumPixels else { return nil }
        let distance = ResolutionEstimate.maximumDistance(
            focalLength: estimate.focalLength,
            pixelsPerMillimetre: settings.featureMinimumPixels / settings.featureSize, sizeScale: estimate.sizeScale)
        let fix =
            distance.map { "Move to \(Self.millimetres($0)) mm or closer, or zoom in." } ?? "Zoom in or move closer."
        return
            "A \(settings.featureSize.formatted()) mm feature gets \(pixels.formatted(.number.precision(.fractionLength(1)))) px; "
            + "it needs \(settings.featureMinimumPixels.formatted()). " + fix
    }

    private func applyDistance() {
        // In the user's locale (e.g. with a decimal comma), with or without
        // grouping.
        let value = try? Double(distanceText.trimmingCharacters(in: .whitespaces), format: .number)
        settings.scaleDistance = value.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        distanceText = settings.scaleDistance.map(Self.editableMillimetres) ?? ""
    }

    /// For display: whole millimetres, grouped.
    private static func millimetres(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    /// For the field: no grouping (so it reads back as typed), up to one
    /// decimal.
    private static func editableMillimetres(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
    }
}

extension ResolutionEstimate {
    /// The estimate for the camera's focal length and image size and the
    /// working distance in `settings`; nil without a distance or focal
    /// length.
    @MainActor
    init?(camera: SonyCamera, settings: AppSettings) {
        guard let distance = settings.scaleDistance, let focalLength = camera.focalLength else { return nil }
        let size = camera.properties[.imageSize]?.currentValue.bitPattern.map { ImageSize(rawValue: $0) }
        self.init(
            focalLength: FocalLength(rawValue: focalLength).millimetres, distance: distance,
            sizeScale: size.map(Self.sizeScale(of:)) ?? 1)
    }
}
