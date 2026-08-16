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
        } else if job.source == .claudeRoutine {
            helpText = "Ticker observes this job but cannot faithfully re-run it. Trigger it from Claude."
            disabledTitle = "Claude routines cannot run from Ticker"
            disabledDetail = "Ticker observes Claude routines but cannot faithfully re-run them. Trigger this routine from Claude."
        } else {
            let reason = job.effectiveRunNowUnavailableReason
                ?? "Ticker cannot faithfully reproduce this job's scheduled execution context."
            helpText = reason
            disabledTitle = "Run Now is unavailable"
            disabledDetail = reason
        }
    }
}

struct JobDetailView: View {
    @ObservedObject var model: AppModel
    let job: Job
    let onBack: () -> Void

    @Binding var selectedRunID: Int64?
    @State private var showManualRunWhy = false
    @State private var showRewriteConfirmation = false

    private var runs: [Run] {
        model.runsByJob[job.id] ?? []
    }

    private var selectedRun: Run? {
        guard let selectedRunID else {
            return nil
        }
        return runs.first { $0.id == selectedRunID }
    }

    private var displayName: String {
        JobDisplayName.candidate(for: job.label)
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationHeader
            Divider()
            if let run = selectedRun {
                selectedRunInspector(run)
            } else {
                jobOverview
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if model.historyLoadState(for: job) == .idle {
                model.loadRuns(for: job)
            }
        }
        .sheet(isPresented: $showRewriteConfirmation) {
            RewriteConfirmationSheet(
                plistName: job.configPath.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? job.label,
                actionTitle: model.wrappingButtonTitle(for: job),
                detail: rewriteConfirmationDetail,
                confirm: {
                    showRewriteConfirmation = false
                    model.toggleWrapping(job)
                },
                cancel: { showRewriteConfirmation = false }
            )
        }
    }

    private var navigationHeader: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
                    .frame(minHeight: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to jobs")
            .accessibilityLabel("Back to jobs")
            Spacer(minLength: 4)
            Text(displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if selectedRun != nil {
                Button {
                    selectedRunID = nil
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show job details")
                .accessibilityLabel("Show job details")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var jobOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                healthSummary
                actionableAlerts
                primaryActions

                if let message = model.actionMessages[job.id] {
                    ActionMessageView(message: message)
                }

                history
                configuration
                advanced
            }
            .padding(12)
        }
    }

    private func selectedRunInspector(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Run inspector")
                    .font(.headline)
                Spacer()
                Text(Self.dateTime(run.startedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            HStack(spacing: 10) {
                RunOutcomeView(outcome: run.outcome)
                Text("Exit code: \(run.exitCode.map(String.init) ?? "—")")
                Text("Duration: \(Self.durationText(run))")
            }
            .font(.caption)
            .accessibilityElement(children: .combine)

            OutputSection(title: "stdout", text: run.stdoutTail)
            OutputSection(title: "stderr", text: run.stderrTail)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(displayName)
            Text(job.label)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(job.label)
                .textSelection(.enabled)
            Text("\(job.provenance.displayName) · \(sourceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var healthSummary: some View {
        Group {
            if let attention = job.attention, attention.requiresAttention {
                HealthSummaryView(
                    color: .red,
                    icon: "xmark.circle.fill",
                    title: "This job cannot run",
                    detail: attention.detail
                )
            } else if let attention = job.attention {
                HealthSummaryView(
                    color: .secondary,
                    icon: "info.circle",
                    title: attention.summary,
                    detail: attention.detail
                )
            } else if !job.enabled {
                HealthSummaryView(
                    color: .secondary,
                    icon: "pause.circle",
                    title: "This job is disabled",
                    detail: "Ticker will keep showing its configuration and existing history."
                )
            } else {
                switch model.outcome(for: job) {
                case .failure:
                    HealthSummaryView(
                        color: .red,
                        icon: "xmark.circle.fill",
                        title: "The last observed run failed",
                        detail: lastEvidenceText
                    )
                case .running:
                    HealthSummaryView(
                        color: .blue,
                        icon: "arrow.triangle.2.circlepath",
                        title: "Running now",
                        detail: lastEvidenceText
                    )
                case .success:
                    HealthSummaryView(
                        color: .green,
                        icon: "checkmark.circle",
                        title: "The last observed run succeeded",
                        detail: lastEvidenceText
                    )
                case .unknown:
                    HealthSummaryView(
                        color: .secondary,
                        icon: "questionmark.circle",
                        title: "No run evidence",
                        detail: noEvidenceText
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var actionableAlerts: some View {
        if let attention = job.attention {
            DetailCallout(
                color: attention.requiresAttention ? .red : .secondary,
                icon: attention.requiresAttention
                    ? "exclamationmark.triangle.fill"
                    : "info.circle",
                title: attentionCalloutTitle(attention),
                detail: attentionCalloutDetail(attention)
            )
        }

        if let skew = job.skew, skew > 3_600,
           let scheduledFor = job.lastScheduledFor,
           let ranAt = job.lastRunAt {
            DetailCallout(
                color: .orange,
                icon: "clock.badge.exclamationmark",
                title: "Ran \(String(format: "%.1fh", skew / 3_600)) late",
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

        if job.runtimeStatusAttribution == .ambiguous {
            DetailCallout(
                color: .orange,
                icon: "questionmark.diamond.fill",
                title: "Runtime status is ambiguous",
                detail: "Another plist uses the same label, so Ticker cannot safely assign launchd's runtime record."
            )
        }

        if let recoveryError = model.recoveryStateError(for: job) {
            DetailCallout(
                color: .red,
                icon: "exclamationmark.triangle.fill",
                title: "Wrapper recovery could not be verified",
                detail: recoveryError
            )
        } else {
            wrapperAlert
        }
    }

    private func attentionCalloutTitle(_ attention: JobAttention) -> String {
        switch attention {
        case .missingPayload:
            return "Missing payload"
        case .malformedConfiguration:
            return "Malformed configuration"
        case .inertConfiguration:
            return "Inert configuration"
        case .unreadableConfiguration:
            return "Unreadable configuration"
        }
    }

    private func attentionCalloutDetail(_ attention: JobAttention) -> String {
        switch attention {
        case .missingPayload(let path):
            return "Ticker found the job, but \(path) does not exist. Restore the file or update the plist command."
        case .malformedConfiguration(let path, let message):
            return "Ticker found \(path), but it is not a valid property list: \(message)"
        case .inertConfiguration:
            return attention.detail
        case .unreadableConfiguration:
            return attention.detail
        }
    }

    @ViewBuilder
    private var wrapperAlert: some View {
        switch model.recoveryState(for: job) {
        case .wrappedMissingBackup:
            DetailCallout(
                color: .orange,
                icon: "wrench.and.screwdriver.fill",
                title: "History wrapper needs repair",
                detail: "Ticker found its wrapper but no verified backup. Repair it before restoring this job."
            )
        case .wrappedBackupContentMismatch:
            DetailCallout(
                color: .red,
                icon: "exclamationmark.shield.fill",
                title: "Backup integrity check failed",
                detail: "Ticker's backup does not match its authenticated metadata, so Ticker will not rewrite this plist."
            )
        case .ambiguousTickerInvocation:
            DetailCallout(
                color: .red,
                icon: "exclamationmark.triangle.fill",
                title: "Unverified wrapper command",
                detail: JobRecoveryState.ambiguousTickerInvocationExplanation
            )
        case .wrappedForeignLabel:
            DetailCallout(
                color: .red,
                icon: "exclamationmark.triangle.fill",
                title: "Unsafe wrapper label",
                detail: "This plist contains a Ticker wrapper for another job. Ticker will not modify it."
            )
        case .identityChanged(let previousJobID):
            DetailCallout(
                color: .orange,
                icon: "arrow.triangle.2.circlepath",
                title: "History identity changed",
                detail: "This wrapper still records as \(previousJobID). Reconcile it before unwrapping."
            )
        case .staleManagedRow:
            DetailCallout(
                color: .orange,
                icon: "externaldrive.badge.exclamationmark",
                title: "Stale history record",
                detail: "The plist was restored outside Ticker. Wrapping it again will replace the stale record."
            )
        case .unwrapped, .wrappedConsistent, .none:
            EmptyView()
        }
    }

    private var primaryActions: some View {
        let busy = model.busyJobIDs.contains(job.id)
        let runNow = JobRunNowPresentation(job: job, busy: busy)
        return HStack(spacing: 8) {
            if job.canRunNow {
                Button {
                    model.runNow(job)
                } label: {
                    Label("Run Now", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!runNow.isEnabled)
                .help(runNow.helpText)
            } else {
                Text("Manual run unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Why?") {
                    showManualRunWhy = true
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .popover(isPresented: $showManualRunWhy, arrowEdge: .top) {
                    Text(runNow.disabledDetail ?? runNow.helpText)
                        .font(.body)
                        .padding(14)
                        .frame(width: 300, alignment: .leading)
                }
            }

            if busy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Run history")
                    .font(.headline)
                Spacer()
                Button {
                    model.loadRuns(for: job)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Reload run history")
                .accessibilityLabel("Reload run history")
            }

            switch model.historyLoadState(for: job) {
            case .idle:
                Label("Run history has not loaded", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Run history has not loaded")
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading run history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Could not load run history", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") {
                        model.loadRuns(for: job)
                    }
                    .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
            case .loaded:
                if runs.isEmpty {
                    historyEmptyState
                } else {
                    VStack(spacing: 2) {
                        ForEach(runs) { run in
                            Button {
                                selectedRunID = run.id
                            } label: {
                                HStack(spacing: 7) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Self.dateTime(run.startedAt))
                                            .lineLimit(1)
                                        Text(run.trigger == .manual ? "Manual" : "Scheduled")
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 2)
                                    RunOutcomeView(outcome: run.outcome)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(Self.durationText(run))
                                        Text("Exit \(run.exitCode.map(String.init) ?? "—")")
                                            .monospaced()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Inspect run from \(Self.dateTime(run.startedAt))")
                            .accessibilityLabel(
                                "Inspect \(run.outcome.rawValue) run from \(Self.dateTime(run.startedAt))"
                            )
                        }
                    }
                }
            }
        }
    }

    private var historyEmptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(historyEmptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if job.provenance.isYours,
               job.source == .launchd,
               job.attention == nil,
               !model.isManaged(job),
               model.canToggleWrapping(job) {
                Button("Enable Run History…") {
                    showRewriteConfirmation = true
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }


    private var configuration: some View {
        DisclosureGroup("Configuration") {
            VStack(alignment: .leading, spacing: 12) {
                DetailField(label: "Command") {
                    ScrollView(.horizontal) {
                        Text(Self.displayCommand(job.command))
                            .font(.caption)
                            .monospaced()
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    .padding(8)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }

                DetailField(label: "Schedule") {
                    Text(job.schedule.humanDescription)
                }

                DetailField(label: "Next fire") {
                    Text(job.nextFireAt.map(Self.dateTime) ?? "Not scheduled")
                        .foregroundStyle(job.nextFireAt == nil ? .secondary : .primary)
                }

                DetailField(label: "Config") {
                    HStack(spacing: 8) {
                        if let configPath = job.configPath {
                            PathText(path: configPath)
                            Button {
                                revealConfig()
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        } else {
                            Text("Not available")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let cwd = job.cwd {
                    DetailField(label: "Working directory") {
                        PathText(path: cwd)
                    }
                }
            }
            .padding(.top, 10)
        }
        .font(.body)
    }

    private var advanced: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 12) {
                if let explanation = job.runtimeStatusExplanation {
                    DisclosureGroup(runtimeDisclosureTitle) {
                        Text(explanation)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 6)
                    }
                }

                let environment = model.runEnvironment(for: job)
                DisclosureGroup("Environment (\(environment.count))") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(environment.keys.sorted(), id: \.self) { name in
                            GridRow {
                                Text(name)
                                    .font(.caption)
                                    .monospaced()
                                    .foregroundStyle(.secondary)
                                Text(environment[name] ?? "")
                                    .font(.caption)
                                    .monospaced()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(environment[name] ?? "")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 6)
                }

                if shouldShowAdvancedWrapping {
                    Divider()
                    Text("Run history integration")
                        .font(.headline)
                    Text("Ticker must rewrite this plist. You will need to reload it after the change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(model.wrappingButtonTitle(for: job)) {
                        showRewriteConfirmation = true
                    }
                    .disabled(model.busyJobIDs.contains(job.id) || !model.canToggleWrapping(job))
                }
            }
            .padding(.top, 10)
        }
    }

    private var historyEmptyText: String {
        if model.isManaged(job) {
            return "No recorded runs yet."
        }
        switch job.source {
        case .launchd:
            return job.provenance.isYours
                ? "Run history is not enabled for this job."
                : "Ticker has no captured history for this app or system job."
        case .crontab:
            return "crontab does not provide run history."
        case .claudeRoutine:
            return "Claude records starts and skips, but not complete outcomes."
        }
    }

    private var shouldShowAdvancedWrapping: Bool {
        guard job.source == .launchd else {
            return false
        }
        return !job.provenance.isYours
            || model.isManaged(job)
            || model.wrapperNeedsAttention(job)
    }

    private var rewriteConfirmationDetail: String {
        "Ticker will rewrite this plist's command. Ticker does not reload launchd jobs automatically; you must run the reload commands shown after the change."
    }

    private var sourceName: String {
        switch job.source {
        case .launchd: return "launchd"
        case .crontab: return "crontab"
        case .claudeRoutine: return "Claude routine"
        }
    }

    private var runtimeDisclosureTitle: String {
        switch job.runtimeStatusAttribution {
        case .ambiguous, .unavailable, .recordWithoutExit:
            return "Why Ticker can’t verify this"
        case .resolved, .neverExited, .none:
            return "Runtime attribution"
        }
    }

    private var noEvidenceText: String {
        if job.source == .launchd {
            return "launchd has no runtime record for this job. It may not be loaded."
        }
        return "Ticker has not observed a completed scheduled run."
    }

    private var lastEvidenceText: String {
        guard let date = job.nativeStatusObservedAt ?? job.lastRunAt else {
            return "Ticker has runtime evidence but no timestamp for it."
        }
        return "Observed \(Self.dateTime(date))."
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

    private static func durationText(_ run: Run) -> String {
        guard let duration = run.duration else {
            return run.outcome == .running ? "Running" : "—"
        }
        return duration >= 60
            ? String(format: "%.1fm", duration / 60)
            : String(format: "%.1fs", duration)
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

private struct HealthSummaryView: View {
    let color: Color
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PathText: View {
    let path: String

    var body: some View {
        Text(path)
            .font(.caption)
            .monospaced()
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
            .textSelection(.enabled)
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
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RunOutcomeView: View {
    let outcome: Outcome

    var body: some View {
        switch outcome {
        case .running:
            Label("Running", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .success:
            Label("Success", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failure:
            Label("Failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unknown:
            Label("Unknown", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct OutputSection: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(displayText)
                    .font(.caption)
                    .monospaced()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(7)
            }
            .frame(minHeight: 86, maxHeight: 128)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayText: String {
        guard let text, !text.isEmpty else {
            return "No captured output"
        }
        return text
    }
}

private struct ActionMessageView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .monospaced()
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct RewriteConfirmationSheet: View {
    let plistName: String
    let actionTitle: String
    let detail: String
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Rewrite \(plistName)?", systemImage: "doc.badge.gearshape")
                .font(.headline)
            Text(detail)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
