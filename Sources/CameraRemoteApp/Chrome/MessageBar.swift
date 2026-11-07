import SwiftUI

/// The window's bottom line, as in Photoshop or Lightroom: what blocks the
/// shutter or the latest message on the left, with its fix; the session's
/// progress and the space left on the right.  Its height never changes, so
/// nothing else moves when a message comes or goes.
struct MessageBar: View {
    let capture: CaptureModel
    let messages: MessageLog

    @State private var isHistoryShown = false
    /// A message is news for a few seconds: shown even over what blocks the
    /// shutter (so a failed Fix or a refused value is seen), and successes
    /// fade back to "Ready" after it.
    @State private var staleEntry: MessageLog.Entry.ID?

    private static let newsLifetime: Duration = .seconds(5)

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isHistoryShown.toggle()
            } label: {
                status
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(statusText + "\nClick for recent messages")
            .popover(isPresented: $isHistoryShown, arrowEdge: .top) {
                MessageHistory(messages: messages)
            }
            action
            Text(progress)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: Layout.messageBarHeight)
        .background(Theme.panel)
        .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        .task(id: messages.current?.id) {
            guard let entry = messages.current, (try? await Task.sleep(for: Self.newsLifetime)) != nil else { return }
            staleEntry = entry.id
        }
    }

    // MARK: - Status

    private enum Shown {
        case capturing
        case blocked(ShutterBlock)
        case message(MessageLog.Entry)
        case ready
    }

    private var shown: Shown {
        if capture.isCapturing { return .capturing }
        let entry = messages.current
        if let entry, entry.id != staleEntry { return .message(entry) }
        if let block = capture.shutterBlock { return .blocked(block) }
        // Problems stay until dismissed; good news fades.
        if let entry, entry.kind == .failure || entry.kind == .warning { return .message(entry) }
        return .ready
    }

    private var statusText: String {
        switch shown {
        case .capturing: "Capturing…"
        case .blocked(let block): block.message
        case .message(let entry): entry.text
        case .ready: "Ready"
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 6) {
            switch shown {
            case .capturing:
                ProgressView().controlSize(.mini)
            case .blocked:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            case .message(let entry):
                Image(systemName: MessageHistory.symbol(for: entry.kind))
                    .foregroundStyle(MessageHistory.color(for: entry.kind))
            case .ready:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.success)
            }
            Text(statusText)
                .foregroundStyle(isQuiet ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12))
    }

    private var isQuiet: Bool {
        if case .ready = shown { return true }
        return false
    }

    /// The one-click fix for what's shown, if there is one.
    @ViewBuilder
    private var action: some View {
        switch shown {
        case .blocked(let block):
            switch block.fix {
            case .enterName:
                barButton(capture.session.sample == nil ? "Enter Name" : "Enter Pallet") { capture.focusSessionName() }
            case .fixSettings:
                barButton("Fix") { Task { await capture.fixSettings() } }
                    .help(capture.settingIssues.map(\.message).joined(separator: "\n"))
            case nil:
                EmptyView()
            }
        case .message(let entry) where entry.kind == .failure || entry.kind == .warning:
            Button {
                messages.dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textSecondary)
            .help("Dismiss")
        default:
            EmptyView()
        }
    }

    private func barButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .underline()
    }

    /// Session · captures · how many more fit on the Mac.
    private var progress: String {
        var parts: [String] = []
        if !capture.session.name.isEmpty {
            parts.append((capture.session.sample == nil ? "" : "Pallet ") + capture.session.name)
        }
        parts.append(capture.captureCount == 1 ? "1 capture" : "\(capture.captureCount) captures")
        if let fit = capture.capturesThatFit { parts.append("~\(fit.formatted()) more fit on Mac") }
        return parts.joined(separator: " · ")
    }
}

/// The last messages, newest first.
private struct MessageHistory: View {
    let messages: MessageLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Messages")
                .font(.headline)
                .padding(10)
            Divider()
            if messages.history.isEmpty {
                Text("Nothing yet.")
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages.history) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: Self.symbol(for: entry.kind))
                                    .foregroundStyle(Self.color(for: entry.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                    Text(entry.date.formatted(date: .omitted, time: .standard))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 420)
        .font(.callout)
    }

    static func symbol(for kind: MessageLog.Entry.Kind) -> String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }

    static func color(for kind: MessageLog.Entry.Kind) -> Color {
        switch kind {
        case .info: Theme.textSecondary
        case .success: Theme.success
        case .warning: Theme.warning
        case .failure: Theme.failure
        }
    }
}
