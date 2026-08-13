import AppKit
import Foundation
import SwiftUI
import TickerCore

struct JobRunNowPresentation: Equatable {
    let isEnabled: Bool
    let helpText: String
    let disabledTitle: String?
    let disabledDetail: String?

    init(job: Job, busy: Bool) {
        isEnabled = !busy && job.canRunNow
        if job.canRunNow {
            helpText = "Run this job now."
            disabledTitle = nil
            disabledDetail = nil
        } else {
            helpText = "Ticker observes this job but cannot faithfully re-run it. Trigger it from Claude."
            disabledTitle = "Claude routines cannot run from Ticker"
            disabledDetail = "Ticker observes Claude routines but cannot faithfully re-run them. Trigger this routine from Claude."
        }
    }
}

struct JobDetailView: View {
    @ObservedObject var model: AppModel
    let job: Job

    @State private var selectedRunID: Int64?

    private var runs: [Run] {
        model.runsByJob[job.id] ?? []
    }

    private var selectedRun: Run? {
        guard let selectedRunID = selectedRunID else {
            return nil
        }
        return runs.first { $0.id == selectedRunID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                callouts
                actionButtons

                if let message = model.actionMessages[job.id] {
                    ActionMessageView(message: message)
                }

                Divider()
                configuration
                Divider()
                history
                output
            }
            .padding(16)
        }
        .onAppear {
            model.loadRuns(for: job)
        }
        .onReceive(model.$runsByJob) { _ in
            if let selectedRunID = selectedRunID,
               runs.contains(where: { $0.id == selectedRunID }) {
                return
            }
            selectedRunID = runs.first?.id
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.label)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                Spacer()
                DetailOutcomeBadge(outcome: model.outcome(for: job))
            }
            Text(job.source == .claudeRoutine ? "Claude routine" : job.source.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var callouts: some View {
        if let skew = job.skew, skew > 3_600,
           let scheduledFor = job.lastScheduledFor,
           let ranAt = job.lastRunAt {
            DetailCallout(
                color: .orange,
                icon: "clock.badge.exclamationmark",
                title: "ran \(String(format: "%.1fh", skew / 3_600)) late",
                detail: "Scheduled \(Self.dateTime(scheduledFor)); started \(Self.dateTime(ranAt))."
            )
        }

        if let skipStorm = model.skipStorm(for: job) {
            DetailCallout(
                color: .orange,
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                title: skipStorm.displayText,
                detail: "First skip \(Self.dateTime(skipStorm.firstSkipAt)); last skip \(Self.dateTime(skipStorm.lastSkipAt))."
            )
        }

        let runNow = JobRunNowPresentation(job: job, busy: model.busyJobIDs.contains(job.id))
        if let title = runNow.disabledTitle, let detail = runNow.disabledDetail {
            DetailCallout(
                color: .blue,
                icon: "play.slash.fill",
                title: title,
                detail: detail
            )
        }


        if let explanation = job.runtimeStatusExplanation {
            DetailCallout(
                color: .orange,
                icon: "questionmark.diamond.fill",
                title: "Runtime status is ambiguous",
                detail: explanation
            )
        }
        if job.source == .launchd {
            if let recoveryError = model.recoveryStateError(for: job) {
                DetailCallout(
                    color: .red,
                    icon: "exclamationmark.triangle.fill",
                    title: "Wrapper recovery could not be verified",
                    detail: recoveryError
                )
            } else {
                switch model.recoveryState(for: job) {
                case .wrappedMissingBackup:
                    DetailCallout(
                        color: .orange,
                        icon: "wrench.and.screwdriver.fill",
                        title: "History wrapper needs repair",
                        detail: "Ticker found its wrapper but no verified backup. Repair the wrapper before you can safely restore this job."
                    )
                case .wrappedBackupContentMismatch:
                    DetailCallout(
                        color: .red,
                        icon: "exclamationmark.shield.fill",
                        title: "Backup integrity check failed",
                        detail: "Ticker's backup does not match its authenticated metadata. Ticker will not rewrite or restore this plist."
                    )
                case .wrappedBackupUnverified:
                    DetailCallout(
                        color: .orange,
                        icon: "questionmark.diamond.fill",
                        title: "Backup cannot be verified",
                        detail: "Ticker's backup has no valid content digest. Explicit recovery is required before Ticker can modify this plist."
                    )
                case .ambiguousTickerInvocation:
                    DetailCallout(
                        color: .red,
                        icon: "exclamationmark.triangle.fill",
                        title: "Unverified ticker command",
                        detail: "This plist invokes an executable named ticker without Ticker's version marker. Ticker will not modify it."
                    )
                case .wrappedForeignLabel:
                    DetailCallout(
                        color: .red,
                        icon: "exclamationmark.triangle.fill",
                        title: "Unsafe wrapper label",
                        detail: "This plist contains a Ticker wrapper for another job. Ticker will not modify it."
                    )
                case .staleManagedRow:
                    DetailCallout(
                        color: .orange,
                        icon: "externaldrive.badge.exclamationmark",
                        title: "Stale history record",
                        detail: "The plist was restored outside Ticker. Wrapping it again will replace the stale record and preserve the current plist."
                    )
                case .unwrapped, .wrappedConsistent, .none:
                    EmptyView()
                }
            }
        }

        if !model.isManaged(job) {
            switch job.source {
            case .launchd:
                DetailCallout(
                    color: .blue,
                    icon: "info.circle.fill",
                    title: "History is not enabled",
                    detail: "launchd keeps only the most recent exit status. Wrap this job to record run times, duration, output, and every outcome."
                )
            case .crontab:
                DetailCallout(
                    color: .blue,
                    icon: "info.circle.fill",
                    title: "History is not enabled",
                    detail: "crontab keeps no run history. Ticker does not modify crontab entries yet."
                )
            case .claudeRoutine:
                DetailCallout(
                    color: .blue,
                    icon: "info.circle.fill",
                    title: "Claude records starts, not outcomes",
                    detail: "Ticker can show late runs and skip storms. Direct history wrapping for Claude routines is not available yet."
                )
            }
        }
    }

    private var actionButtons: some View {
        let busy = model.busyJobIDs.contains(job.id)
        let presentation = JobRunNowPresentation(
            job: job,
            busy: busy
        )
        return HStack(spacing: 8) {
            Button {
                model.runNow(job)
            } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .disabled(!presentation.isEnabled)
            .help(presentation.helpText)

            Button {
                revealConfig()
            } label: {
                Label("Reveal Config in Finder", systemImage: "folder")
            }
            .disabled(job.configPath == nil)

            Button {
                model.toggleWrapping(job)
            } label: {
                Label(
                    model.wrappingButtonTitle(for: job),
                    systemImage: model.wrappingButtonIcon(for: job)
                )
            }
            .disabled(busy || !model.canToggleWrapping(job))
            .help(wrappingHelp)

            if busy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .controlSize(.small)
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configuration")
                .font(.headline)

            DetailField(label: "Command") {
                Text(Self.displayCommand(job.command))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            DetailField(label: "Schedule") {
                Text(job.schedule.humanDescription)
            }

            DetailField(label: "Next fire") {
                if let nextFire = job.nextFireAt {
                    Text(Self.dateTime(nextFire))
                } else {
                    Text(job.schedule.humanDescription)
                }
            }

            DetailField(label: "Config") {
                if let configPath = job.configPath {
                    Text(configPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("Not available")
                        .foregroundColor(.secondary)
                }
            }

            if let cwd = job.cwd {
                DetailField(label: "Working directory") {
                    Text(cwd)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if job.canRunNow {
                let environment = model.runEnvironment(for: job)
                DetailField(label: "Run Now environment") {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Scheduler defaults, then job variables:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(environment.keys.sorted(), id: \.self) { name in
                            Text("\(name)=\(environment[name] ?? "")")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 20 runs")
                    .font(.headline)
                Spacer()
                Button {
                    model.loadRuns(for: job)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload run history")
            }

            if runs.isEmpty {
                Text(model.isManaged(job) ? "No recorded runs yet." : "Wrap this job to start recording runs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 3) {
                    ForEach(runs) { run in
                        RunHistoryRow(run: run, selected: selectedRunID == run.id) {
                            selectedRunID = run.id
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var output: some View {
        if let run = selectedRun {
            VStack(alignment: .leading, spacing: 8) {
                Text("Captured output")
                    .font(.headline)

                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 12) {
                        OutputSection(title: "stdout", text: run.stdoutTail)
                        OutputSection(title: "stderr", text: run.stderrTail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(minHeight: 120, maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
    }

    private var wrappingHelp: String {
        switch job.source {
        case .launchd:
            return "Rewrite this job to run through the Ticker history recorder."
        case .crontab:
            return "crontab wrapping is not available yet."
        case .claudeRoutine:
            return "Claude routine wrapping is on the roadmap."
        }
    }
    private func revealConfig() {
        guard let configPath = job.configPath else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    private static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func displayCommand(_ command: [String]) -> String {
        if command.isEmpty {
            return "No command"
        }
        return command.map { argument in
            guard argument.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else {
                return argument
            }
            return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: " ")
    }
}

private struct DetailField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 92, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailCallout: View {
    let color: Color
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.bold())
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DetailOutcomeBadge: View {
    let outcome: Outcome

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundColor(color)
    }

    private var title: String {
        switch outcome {
        case .running:
            return "Running"
        case .success:
            return "Success"
        case .failure:
            return "Failure"
        case .unknown:
            return "Unknown"
        }
    }

    private var icon: String {
        switch outcome {
        case .running:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var color: Color {
        switch outcome {
        case .running:
            return .blue
        case .success:
            return .green
        case .failure:
            return .red
        case .unknown:
            return .gray
        }
    }
}

private struct RunHistoryRow: View {
    let run: Run
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Circle()
                    .fill(outcomeColor)
                    .frame(width: 7, height: 7)
                Text(Self.dateTime(run.startedAt))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(durationText)
                    .foregroundColor(.secondary)
                    .frame(width: 62, alignment: .trailing)
                Text(exitText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var outcomeColor: Color {
        switch run.outcome {
        case .running:
            return .blue
        case .success:
            return .green
        case .failure:
            return .red
        case .unknown:
            return .gray
        }
    }

    private var durationText: String {
        guard let duration = run.duration else {
            return run.outcome == .running ? "running" : "—"
        }
        if duration >= 60 {
            return String(format: "%.1fm", duration / 60)
        }
        return String(format: "%.1fs", duration)
    }

    private var exitText: String {
        guard let exitCode = run.exitCode else {
            return "exit —"
        }
        return "exit \(exitCode)"
    }

    private static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct OutputSection: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)
            Text(displayText)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private var displayText: String {
        guard let text = text, !text.isEmpty else {
            return "No captured output"
        }
        return text
    }
}

private struct ActionMessageView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
