import SonyProtocol

/// Setting several properties at once, as a preset does.
extension SonyCamera {
    /// Why a setting wasn't applied.
    public enum SettingSkip: Equatable, Sendable {
        /// The camera doesn't report the property (another model or lens).
        case notOffered
        /// Not settable to this value now — e.g. the exposure mode owns it,
        /// or the value isn't in the camera's list — or refused when sent
        /// (e.g. busy writing to the card).
        case notAccepted
        /// Sent, but the camera didn't take it in time.
        case notApplied
    }

    /// Sets each of `settings`, in order, waiting for each to take before
    /// the next — later settings often depend on earlier ones (aperture on
    /// the exposure mode, kelvin on white balance).  Settings already right
    /// are left alone.  Returns the ones skipped, in order; throws only if
    /// the camera can't be reached.
    public func apply(_ settings: [(code: SonyPropertyCode, value: PTPValue)]) async throws
        -> [(code: SonyPropertyCode, skip: SettingSkip)]
    {
        try await refreshProperties()
        var skipped: [(code: SonyPropertyCode, skip: SettingSkip)] = []
        for (code, value) in settings {
            guard let descriptor = properties[code] else {
                skipped.append((code, .notOffered))
                continue
            }
            guard descriptor.currentValue != value else { continue }
            guard descriptor.accepts(value) else {
                skipped.append((code, .notAccepted))
                continue
            }
            do {
                try await setProperty(code, to: value)
            } catch PTPSessionError.rejected {
                skipped.append((code, .notAccepted))
                continue
            }
            do {
                try await waitForProperty(code, toBe: value)
            } catch SonyCameraError.settingNotApplied {
                skipped.append((code, .notApplied))
            }
        }
        return skipped
    }

    /// Fixes every capture setting that's wrong (`CaptureSettings`), in the
    /// order they must land, each only if the camera offers its value by
    /// then — one fixed earlier can make the next settable.  Returns the
    /// issues left, with why; throws only if the camera can't be reached.
    public func fixCaptureSettings() async throws -> [(issue: CaptureSettingIssue, skip: SettingSkip)] {
        try await refreshProperties()
        let issues = CaptureSettings.issues(in: properties)
        let skipped = try await apply(issues.map { ($0.code, $0.requiredValue) })
        return skipped.compactMap { code, skip in
            issues.first { $0.code == code }.map { ($0, skip) }
        }
    }
}
