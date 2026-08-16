import AppKit
import Foundation
import SwiftUI
import TickerCore

enum JobNextFirePresentation {
    static func relativeText(
        for schedule: Schedule,
        nextFire: Date?,
        relativeTo now: Date = Date()
    ) -> String? {
        guard let nextFire else {
            return nil
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: nextFire, relativeTo: now)
    }
}

enum JobDisplayName {
    static func candidate(for label: String) -> String {
        guard let component = label.split(separator: ".").last else {
            return label
        }
        let raw = String(component)
        let words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard words.count >= 2,
              words.allSatisfy({ word in
                  !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber }
              })
        else {
            return label
        }
        let joined = words.map(String.init).joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    static func disambiguated(for job: Job, among jobs: [Job]) -> String {
        let candidate = candidate(for: job.label)
        let collisions = jobs.filter { Self.candidate(for: $0.label) == candidate }
        guard collisions.count > 1 else {
            return candidate
        }
        if Set(collisions.map(\.label)).count == collisions.count {
            return job.label
        }
        let locationDisplay = "\(job.label) — \(locationName(for: job))"
        let locationCollisions = collisions.filter {
            "\($0.label) — \(locationName(for: $0))" == locationDisplay
        }
        guard locationCollisions.count > 1 else {
            return locationDisplay
        }
        let plistName = job.configPath.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? job.source.rawValue
        let pathDisplay = "\(locationDisplay) · \(plistName)"
        let pathCollisions = locationCollisions.filter {
            let otherName = $0.configPath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? $0.source.rawValue
            return "\($0.label) — \(locationName(for: $0)) · \(otherName)" == pathDisplay
        }
        guard pathCollisions.count > 1 else {
            return pathDisplay
        }
        let shortID = job.id.split(separator: "#").last.map {
            String($0.prefix(6))
        } ?? String(job.id.suffix(6))
        return "\(pathDisplay) · \(shortID)"
    }

    private static func locationName(for job: Job) -> String {
        guard let path = job.configPath else {
            return job.source.rawValue
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home || path.hasPrefix(home + "/") {
            return "User"
        }
        if path.hasPrefix("/Library/LaunchDaemons/") {
            return "System"
        }
        if path.hasPrefix("/Library/LaunchAgents/") {
            return "Local"
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }
}

struct JobRunHistoryCell: Identifiable {
    let id: Int64
    let outcome: Outcome
    let symbolName: String
    let statusText: String
    let accessibilityLabel: String
}

struct JobRunSelection: Equatable {
    let jobID: String
    let runID: Int64
}

struct JobRunNavigationState: Equatable {
    private(set) var selectedJobID: String?
    private(set) var selectedRunIDs: [String: Int64] = [:]

    mutating func selectJob(_ jobID: String) {
        selectedJobID = jobID
        selectedRunIDs[jobID] = nil
    }

    mutating func selectRun(_ selection: JobRunSelection) {
        selectedJobID = selection.jobID
        selectedRunIDs[selection.jobID] = selection.runID
    }

    mutating func showJobDetails(for jobID: String) {
        selectedRunIDs[jobID] = nil
    }

    mutating func returnToList() {
        selectedJobID = nil
    }

    mutating func reconcileJobs(_ availableJobIDs: [String]) {
        guard let selectedJobID else {
            return
        }
        if !availableJobIDs.contains(selectedJobID) {
            self.selectedJobID = nil
        }
    }

    mutating func reconcileRuns(for jobID: String, with runs: [Run]) {
        guard let selectedRunID = selectedRunIDs[jobID] else {
            return
        }
        if runs.contains(where: { $0.id == selectedRunID }) {
            return
        }
        selectedRunIDs[jobID] = runs.first?.id
    }

    func selectedRunID(for jobID: String) -> Int64? {
        selectedRunIDs[jobID]
    }

    func selectedRun(for jobID: String, in runs: [Run]) -> Run? {
        guard let selectedRunID = selectedRunID(for: jobID) else {
            return nil
        }
        return runs.first { $0.id == selectedRunID }
    }
}

enum JobRunHistoryPresentation {
    static let maximumVisibleRuns = 5

    static func cells(
        from runs: [Run],
        limit: Int = maximumVisibleRuns
    ) -> [JobRunHistoryCell] {
        guard limit > 0 else {
            return []
        }
        let recentRuns = runs.prefix(limit)
        let count = recentRuns.count
        return recentRuns.reversed().enumerated().map { index, run in
            let presentation = outcomePresentation(for: run.outcome)
            let exitText = run.exitCode.map { ", exit code \($0)" } ?? ""
            return JobRunHistoryCell(
                id: run.id,
                outcome: run.outcome,
                symbolName: presentation.symbolName,
                statusText: presentation.statusText,
                accessibilityLabel:
                    "Recent run \(index + 1) of \(count): \(presentation.statusText)\(exitText)"
            )
        }
    }

    static func selection(
        jobID: String,
        cell: JobRunHistoryCell
    ) -> JobRunSelection {
        JobRunSelection(jobID: jobID, runID: cell.id)
    }

    private static func outcomePresentation(
        for outcome: Outcome
    ) -> (symbolName: String, statusText: String) {
        switch outcome {
        case .success:
            return ("checkmark.circle.fill", "Succeeded")
        case .failure:
            return ("xmark.square.fill", "Failed")
        case .running:
            return ("clock.fill", "Running")
        case .unknown:
            return ("questionmark.diamond.fill", "Unknown result")
        }
    }
}

struct JobListView: View {
    @ObservedObject var model: AppModel
    @State private var navigationState = JobRunNavigationState()
    @State private var searchText = ""
    @AppStorage("ticker.otherJobsExpanded") private var otherJobsExpanded = false
    @AppStorage("ticker.tickerJobsExpanded") private var tickerJobsExpanded = true
    @AppStorage("ticker.appsExpanded") private var appsExpanded = true
    @AppStorage("ticker.packageManagersExpanded") private var packageManagersExpanded = true
    @AppStorage("ticker.systemJobsExpanded") private var systemJobsExpanded = true

    private var selectedJob: Job? {
        guard let selectedJobID = navigationState.selectedJobID else {
            return nil
        }
        return matchingJobs.first { $0.id == selectedJobID }
    }

    private var matchingJobs: [Job] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return model.jobs
        }
        return model.jobs.filter(matchesSearch)
    }

    private var yourJobs: [Job] {
        sorted(matchingJobs.filter { $0.provenance.isYours })
    }

    private var allYourJobs: [Job] {
        model.jobs.filter { $0.provenance.isYours }
    }

    private var otherJobs: [Job] {
        matchingJobs.filter { $0.provenance.isConfirmedThirdParty }
    }

    private var allOtherJobs: [Job] {
        model.jobs.filter { $0.provenance.isConfirmedThirdParty }
    }

    private var unattributedJobs: [Job] {
        sorted(matchingJobs.filter {
            if case .unknown = $0.provenance { return true }
            return false
        })
    }

    private var allUnattributedJobs: [Job] {
        model.jobs.filter {
            if case .unknown = $0.provenance { return true }
            return false
        }
    }

    private var appJobs: [Job] {
        sorted(otherJobs.filter {
            if case .app = $0.provenance { return true }
            return false
        })
    }

    private var tickerJobs: [Job] {
        sorted(otherJobs.filter { $0.provenance == .ticker })
    }

    private var packageManagerJobs: [Job] {
        sorted(otherJobs.filter {
            if case .packageManager = $0.provenance { return true }
            return false
        })
    }

    private var systemJobs: [Job] {
        sorted(otherJobs.filter { $0.provenance == .system })
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if let job = selectedJob {
                JobDetailView(
                    model: model,
                    job: job,
                    onBack: { navigationState.returnToList() },
                    selectedRunID: runSelectionBinding(for: job.id)
                )
                .id(job.id)
            } else {
                sidebar
            }
        }
        .frame(width: 298, height: 529)
        .onReceive(model.$jobs) { jobs in
            navigationState.reconcileJobs(
                visibleJobs(in: jobs).map(\.id)
            )
        }
        .onReceive(model.$runsByJob) { updatedRunsByJob in
            guard let jobID = navigationState.selectedJobID,
                  let updatedRuns = updatedRunsByJob[jobID] else {
                return
            }
            navigationState.reconcileRuns(for: jobID, with: updatedRuns)
        }
        .onChange(of: searchText) { _ in
            navigationState.reconcileJobs(matchingJobs.map(\.id))
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            List(selection: jobSelectionBinding) {
                if model.jobs.isEmpty {
                    emptyState
                } else {
                    Section("My Jobs") {
                        if yourJobs.isEmpty, isSearching {
                            Text("No matching jobs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        jobRows(yourJobs)
                    }

                    if !unattributedJobs.isEmpty {
                        Section("Needs Review") {
                            jobRows(unattributedJobs)
                        }
                    }

                    if !allOtherJobs.isEmpty {
                        DisclosureGroup(isExpanded: otherExpansion) {
                            provenanceSubgroups
                        } label: {
                            otherJobsHeader
                        }
                    }
                }

                if !model.errors.isEmpty {
                    ErrorSummaryView(errors: model.errors)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, prompt: "Search jobs")
            .environment(\.defaultMinListRowHeight, 32)
        }
    }

    private var sidebarHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ticker")
                    .font(.title3.weight(.semibold))
                Text(yourSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.errors.isEmpty || Date().timeIntervalSince(model.lastRefresh) > 60 {
                    Text(refreshStatus)
                        .font(.caption)
                        .foregroundStyle(model.errors.isEmpty ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            Menu {
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Divider()
                LoginItemMenuSection()
                Divider()
                Button("Quit Ticker") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Ticker menu")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var provenanceSubgroups: some View {
        if !tickerJobs.isEmpty {
            DisclosureGroup(
                isExpanded: subgroupExpansion(
                    $tickerJobsExpanded,
                    hasMatches: !tickerJobs.isEmpty
                )
            ) {
                jobRows(tickerJobs)
            } label: {
                subgroupHeader("Ticker", count: tickerJobs.count)
            }
        }

        if !appJobs.isEmpty {
            DisclosureGroup(isExpanded: subgroupExpansion($appsExpanded, hasMatches: !appJobs.isEmpty)) {
                ForEach(appOwnerNames, id: \.self) { owner in
                    Text(owner)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    jobRows(appJobs.filter { $0.provenance.displayName == owner })
                }
            } label: {
                subgroupHeader("Apps", count: appJobs.count)
            }
        }

        if !packageManagerJobs.isEmpty {
            DisclosureGroup(
                isExpanded: subgroupExpansion(
                    $packageManagersExpanded,
                    hasMatches: !packageManagerJobs.isEmpty
                )
            ) {
                jobRows(packageManagerJobs)
            } label: {
                subgroupHeader("Package Managers", count: packageManagerJobs.count)
            }
        }

        if !systemJobs.isEmpty {
            DisclosureGroup(
                isExpanded: subgroupExpansion($systemJobsExpanded, hasMatches: !systemJobs.isEmpty)
            ) {
                jobRows(systemJobs)
            } label: {
                subgroupHeader("System", count: systemJobs.count)
            }
        }
    }

    private func jobRows(_ jobs: [Job]) -> some View {
        ForEach(jobs) { job in
            JobRow(
                job: job,
                displayName: JobDisplayName.disambiguated(for: job, among: jobs),
                outcome: model.outcome(for: job),
                skipStorm: model.skipStorm(for: job),
                wrapperNeedsAttention: model.wrapperNeedsAttention(job),
                historyLoadState: model.historyLoadState(for: job),
                runs: model.runsByJob[job.id] ?? [],
                onOpenDetails: { navigationState.selectJob(job.id) },
                onReloadHistory: { model.loadRuns(for: job) },
                onSelectRun: selectRun
            )
            .onAppear {
                if model.historyLoadState(for: job) == .idle {
                    model.loadRuns(for: job)
                }
            }
            .tag(job.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No scheduled jobs found")
                .font(.headline)
            Text("Ticker checked launchd, crontab, and Claude routines.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var otherJobsHeader: some View {
        let issueCount = allOtherJobs.filter(model.needsAttention).count
        return HStack {
            Text("Other Jobs")
            Text("\(allOtherJobs.count)")
                .foregroundStyle(.secondary)
            Spacer()
            if issueCount > 0 {
                Label("\(issueCount) \(issueCount == 1 ? "issue" : "issues")", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func subgroupHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var yourSummary: String {
        let issueCount = allYourJobs.filter(model.needsAttention).count
        return "\(issueCount) of your \(allYourJobs.count) jobs \(issueCount == 1 ? "needs" : "need") attention"
    }

    private var refreshStatus: String {
        if !model.errors.isEmpty {
            return "Refresh has issues"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated " + formatter.localizedString(for: model.lastRefresh, relativeTo: Date())
    }

    private var otherExpansion: Binding<Bool> {
        Binding(
            get: {
                otherJobsExpanded
                    || (allYourJobs.isEmpty && !allOtherJobs.isEmpty
                        && allUnattributedJobs.isEmpty)
                    || (isSearching && !otherJobs.isEmpty)
            },
            set: { if !isSearching { otherJobsExpanded = $0 } }
        )
    }

    private func subgroupExpansion(
        _ stored: Binding<Bool>,
        hasMatches: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { stored.wrappedValue || (isSearching && hasMatches) },
            set: { if !isSearching { stored.wrappedValue = $0 } }
        )
    }

    private var appOwnerNames: [String] {
        Array(Set(appJobs.map(\.provenance.displayName))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func matchesSearch(_ job: Job) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        switch job.source {
        case .launchd: source = "launchd"
        case .crontab: source = "crontab"
        case .claudeRoutine: source = "Claude routine"
        }
        let fields = [
            JobDisplayName.candidate(for: job.label),
            job.label,
            job.provenance.displayName,
            source,
            job.command.joined(separator: " "),
            job.configPath ?? "",
            job.cwd ?? "",
        ]
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sorted(_ jobs: [Job]) -> [Job] {
        let now = Date()
        return jobs.sorted { left, right in
            let leftRank = rank(left)
            let rightRank = rank(right)
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            let leftNextFire = left.schedule.nextFire(after: now, calendar: .current)
            let rightNextFire = right.schedule.nextFire(after: now, calendar: .current)
            switch (leftNextFire, rightNextFire) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate < rightDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                let leftName = JobDisplayName.candidate(for: left.label)
                let rightName = JobDisplayName.candidate(for: right.label)
                if leftName == rightName {
                    return left.label < right.label
                }
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
        }
    }

    private func visibleJobs(in jobs: [Job]) -> [Job] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return jobs
        }
        return jobs.filter(matchesSearch)
    }


    private func selectRun(_ selection: JobRunSelection) {
        navigationState.selectRun(selection)
    }

    private var jobSelectionBinding: Binding<String?> {
        Binding(
            get: { navigationState.selectedJobID },
            set: { jobID in
                if let jobID {
                    navigationState.selectJob(jobID)
                }
            }
        )
    }

    private func runSelectionBinding(for jobID: String) -> Binding<Int64?> {
        Binding(
            get: { navigationState.selectedRunID(for: jobID) },
            set: { runID in
                if let runID {
                    navigationState.selectRun(JobRunSelection(jobID: jobID, runID: runID))
                } else {
                    navigationState.showJobDetails(for: jobID)
                }
            }
        )
    }

    private func rank(_ job: Job) -> Int {
        if model.needsAttention(job) { return 0 }
        if !job.enabled { return 4 }
        switch model.outcome(for: job) {
        case .running: return 1
        case .unknown: return 2
        case .success: return 3
        case .failure: return 0
        }
    }
}

private struct JobRow: View {
    let job: Job
    let displayName: String
    let outcome: Outcome
    let skipStorm: SkipStormSummary?
    let wrapperNeedsAttention: Bool
    let historyLoadState: JobHistoryLoadState
    let runs: [Run]
    let onOpenDetails: () -> Void
    let onReloadHistory: () -> Void
    let onSelectRun: (JobRunSelection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 5) {
                Text(displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                status
                    .fixedSize(horizontal: true, vertical: true)
                rowMenu
            }
            HStack(spacing: 4) {
                Text(job.schedule.humanDescription)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let nextFire = JobNextFirePresentation.relativeText(
                    for: job.schedule,
                    nextFire: job.nextFireAt
                ) {
                    Text("· next \(nextFire)")
                        .lineLimit(1)
                }
                Spacer(minLength: 3)
                if let evidenceText {
                    Text(evidenceText)
                        .lineLimit(1)
                }
                RecentRunHistoryView(
                    jobID: job.id,
                    loadState: historyLoadState,
                    cells: JobRunHistoryPresentation.cells(from: runs),
                    onSelect: onSelectRun
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(job.label)
    }

    private var rowMenu: some View {
        Menu {
            Button(action: onOpenDetails) {
                Label("Open Details", systemImage: "sidebar.right")
            }
            Button(action: onReloadHistory) {
                Label("Reload Run History", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 12, height: 12)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28, height: 24, alignment: .center)
        .fixedSize()
        .help("Actions for \(displayName)")
        .accessibilityLabel("Actions for \(displayName)")
    }

    @ViewBuilder
    private var status: some View {
        if let attention = job.attention {
            AttentionBadge(
                title: attention.summary,
                icon: attention.requiresAttention
                    ? "exclamationmark.triangle.fill"
                    : "info.circle",
                color: attention.requiresAttention ? .red : .secondary
            )
        } else if outcome == .failure {
            AttentionBadge(title: "Failed", icon: "xmark.circle.fill", color: .red)
        } else if let skew = job.skew, skew > 3_600 {
            AttentionBadge(title: "Late", icon: "clock.badge.exclamationmark", color: .orange)
        } else if skipStorm != nil {
            AttentionBadge(
                title: "Skip storm",
                icon: "exclamationmark.arrow.triangle.2.circlepath",
                color: .orange
            )
        } else if job.runtimeStatusAttribution == .ambiguous {
            AttentionBadge(title: "Ambiguous", icon: "questionmark.diamond.fill", color: .orange)
        } else if wrapperNeedsAttention {
            AttentionBadge(
                title: "Wrapper damaged",
                icon: "wrench.and.screwdriver.fill",
                color: .orange
            )
        } else if !job.enabled {
            Label("Disabled", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            QuietStatus(outcome: outcome)
        }
    }

    private var evidenceText: String? {
        switch outcome {
        case .running:
            return "Running now"
        case .success:
            return relativeEvidence(prefix: "Last succeeded")
        case .failure:
            return relativeEvidence(prefix: "Last failed")
        case .unknown:
            if let lastRunAt = job.lastRunAt {
                return relativeEvidence(prefix: "Last observed", date: lastRunAt)
            }
            return job.attention == nil ? nil : "No run evidence"
        }
    }

    private func relativeEvidence(prefix: String, date: Date? = nil) -> String {
        guard let observedAt = date ?? job.nativeStatusObservedAt ?? job.lastRunAt else {
            return prefix
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "\(prefix) \(formatter.localizedString(for: observedAt, relativeTo: Date()))"
    }
}

private struct RecentRunHistoryView: View {
    let jobID: String
    let loadState: JobHistoryLoadState
    let cells: [JobRunHistoryCell]
    let onSelect: (JobRunSelection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent run history")
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            Image(systemName: "clock")
                .frame(width: 20, height: 20)
                .accessibilityLabel("Run history not loaded")
                .help("Run history not loaded")
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 20, height: 20)
                .accessibilityLabel("Loading run history")
                .help("Loading run history")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 20, height: 20)
                .accessibilityLabel("Run history failed to load: \(message)")
                .help("Run history failed to load: \(message)")
        case .loaded:
            if cells.isEmpty {
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("No recent runs")
                    .help("No recent runs")
            } else {
                ForEach(cells) { cell in
                    Button {
                        onSelect(
                            JobRunHistoryPresentation.selection(
                                jobID: jobID,
                                cell: cell
                            )
                        )
                    } label: {
                        Image(systemName: cell.symbolName)
                            .font(.system(size: 9, weight: .bold))
                            .symbolRenderingMode(.monochrome)
                            .frame(width: 12, height: 12)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(color(for: cell.outcome))
                    .help(cell.accessibilityLabel)
                    .accessibilityLabel(cell.accessibilityLabel)
                }
            }
        }
    }

    private func color(for outcome: Outcome) -> Color {
        switch outcome {
        case .success:
            return .green
        case .failure:
            return .red
        case .running:
            return .blue
        case .unknown:
            return .secondary
        }
    }
}

private struct AttentionBadge: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }
}

private struct QuietStatus: View {
    let outcome: Outcome

    var body: some View {
        Group {
            switch outcome {
            case .running:
                Label("Running", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
            case .success:
                Label("Succeeded", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .failure:
                Label("Failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unknown:
                Label("No run evidence", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

private struct ErrorSummaryView: View {
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Some sources could not be refreshed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Text(error)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyJobDetailView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a job")
                .font(.headline)
            Text("Health, run history, and configuration appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Open at Login" control. Reads live system state every time the menu opens so
/// the checkmark can never disagree with reality, and reports the real reason
/// when enabling fails — a silent failure here would leave the owner believing
/// monitoring starts at login when it does not.
struct LoginItemMenuSection: View {
    private let controller = LoginItemController()
    @State private var state: LoginItemState = .disabled

    var body: some View {
        Group {
            Button {
                state = state.isOn ? controller.disable() : controller.enable()
            } label: {
                Label(
                    "Open at Login",
                    systemImage: state.isOn ? "checkmark.circle.fill" : "circle"
                )
            }
            .disabled(isBlocked)

            if let note = explanation {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { state = controller.installationProblem() ?? controller.state() }
    }

    private var isBlocked: Bool {
        if case .notInstalled = state { return true }
        return false
    }

    private var explanation: String? {
        switch state {
        case .enabled(let mechanism) where mechanism == .launchAgent:
            return "Enabled via a LaunchAgent."
        case .enabled:
            return nil
        case .disabled:
            return nil
        case .requiresApproval:
            return "Approve Ticker in System Settings › General › Login Items."
        case .notInstalled(_, let expected):
            return "Run the copy in \(expected) to enable this."
        case .failed(let reason):
            return "Could not change this: \(reason)"
        }
    }
}
