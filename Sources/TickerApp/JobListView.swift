import AppKit
import Foundation
import SwiftUI
import TickerCore

enum TickerPopoverLayout {
    static let width: CGFloat = 360
}

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
        let components = label.split(separator: ".").map(String.init)
        guard let finalComponent = components.last else {
            return label
        }
        if let humanized = humanized(finalComponent) {
            return humanized
        }
        if components.count >= 3 {
            let contextComponent = components[components.count - 2]
            if let humanized = humanized(contextComponent + "-" + finalComponent) {
                return humanized
            }
        }
        return label
    }

    static func disambiguated(for job: Job, among jobs: [Job]) -> String {
        let candidate = candidate(for: job.label)
        let collisions = jobs.filter { Self.candidate(for: $0.label) == candidate }
        guard collisions.count > 1 else {
            return candidate
        }

        let variantDisplay = "\(candidate) — \(variantName(for: job))"
        let variantCollisions = collisions.filter {
            "\(candidate) — \(variantName(for: $0))" == variantDisplay
        }
        guard variantCollisions.count > 1 else {
            return variantDisplay
        }

        let locationDisplay = "\(candidate) — \(locationName(for: job))"
        let locationCollisions = variantCollisions.filter {
            "\(candidate) — \(locationName(for: $0))" == locationDisplay
        }
        guard locationCollisions.count > 1 else {
            return locationDisplay
        }

        let plistName = job.configPath.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        } ?? job.source.rawValue
        let pathDisplay = "\(locationDisplay) · \(plistName)"
        let pathCollisions = locationCollisions.filter {
            let otherName = $0.configPath.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            } ?? $0.source.rawValue
            return "\(locationDisplay) · \(otherName)" == pathDisplay
        }
        guard pathCollisions.count > 1 else {
            return pathDisplay
        }

        let shortID = job.id.split(separator: "#").last.map {
            String($0.prefix(6))
        } ?? String(job.id.suffix(6))
        return "\(pathDisplay) · \(shortID)"
    }

    private static func humanized(_ value: String) -> String? {
        let words = value.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard words.count >= 2,
              words.allSatisfy({ word in
                  !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber }
              })
        else {
            return nil
        }
        let joined = words.map(String.init).joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func variantName(for job: Job) -> String {
        if job.managed || job.provenance == .ticker {
            return "Ticker"
        }
        switch job.source {
        case .launchd:
            return "Launchd"
        case .crontab:
            return "Cron"
        case .claudeRoutine:
            return "Claude"
        }
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
        job: Job? = nil,
        limit: Int = maximumVisibleRuns
    ) -> [JobRunHistoryCell] {
        guard limit > 0 else {
            return []
        }
        let recentRuns = runs.prefix(limit)
        let count = recentRuns.count
        return recentRuns.reversed().enumerated().map { index, run in
            let outcome = run.observedOutcome(for: job)
            let presentation = outcomePresentation(for: outcome)
            let exitText = run.exitCode.map { ", exit code \($0)" } ?? ""
            return JobRunHistoryCell(
                id: run.id,
                outcome: outcome,
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
            return ("checkmark", "Succeeded")
        case .failure:
            return ("xmark", "Failed")
        case .running:
            return ("ellipsis", "Running")
        case .interrupted:
            return ("exclamationmark.triangle.fill", "Interrupted")
        case .unknown:
            return ("questionmark", "Unknown result")
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

    private var attentionYourJobs: [Job] {
        yourJobs.filter(model.needsAttention)
    }

    private var remainingYourJobs: [Job] {
        yourJobs.filter { !model.needsAttention($0) }
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
        .frame(width: TickerPopoverLayout.width, height: 529)
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
                    if !attentionYourJobs.isEmpty {
                        Section {
                            jobRows(attentionYourJobs, namingContext: yourJobs)
                        } header: {
                            listSectionHeader(
                                "Needs Attention",
                                count: attentionYourJobs.count,
                                color: .red
                            )
                        }
                    }

                    if !remainingYourJobs.isEmpty || (yourJobs.isEmpty && isSearching) {
                        Section {
                            if yourJobs.isEmpty, isSearching {
                                Text("No matching jobs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            jobRows(remainingYourJobs, namingContext: yourJobs)
                        } header: {
                            listSectionHeader("My Jobs", count: remainingYourJobs.count)
                        }
                    }

                    if !unattributedJobs.isEmpty {
                        Section {
                            jobRows(unattributedJobs)
                        } header: {
                            listSectionHeader("Needs Review", count: unattributedJobs.count)
                        }
                    }

                    if !allOtherJobs.isEmpty && (!isSearching || !otherJobs.isEmpty) {
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
                    let ownerJobs = appJobs.filter { $0.provenance.displayName == owner }
                    subgroupHeader(owner, count: ownerJobs.count)
                        .padding(.leading, 6)
                    jobRows(ownerJobs)
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

    private func jobRows(
        _ jobs: [Job],
        namingContext: [Job]? = nil
    ) -> some View {
        let allNames = namingContext ?? jobs
        return ForEach(jobs) { job in
            JobRow(
                job: job,
                displayName: JobDisplayName.disambiguated(for: job, among: allNames),
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
        let visibleJobs = isSearching ? otherJobs : allOtherJobs
        let issueCount = visibleJobs.filter(model.needsAttention).count
        return HStack {
            Text("Other Jobs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(visibleJobs.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if issueCount > 0 {
                Label(
                    "\(issueCount) \(issueCount == 1 ? "issue" : "issues")",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private func listSectionHeader(
        _ title: String,
        count: Int,
        color: Color = .secondary
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .textCase(nil)
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
        let jobCount = allYourJobs.count
        let jobNoun = jobCount == 1 ? "job" : "jobs"
        let issueCount = allYourJobs.filter(model.needsAttention).count
        if issueCount == 0 {
            return "\(jobCount) \(jobNoun) monitored"
        }
        let attentionVerb = issueCount == 1 ? "needs" : "need"
        return "\(issueCount) \(attentionVerb) attention · \(jobCount) \(jobNoun) monitored"
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
        case .interrupted: return 0
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                Text(displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                status
                    .fixedSize(horizontal: true, vertical: true)
                rowMenu
            }
            HStack(spacing: 6) {
                Text(job.schedule.humanDescription)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                    .help(job.schedule.humanDescription)
                Spacer(minLength: 4)
                if let nextFireText {
                    Text(nextFireText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                RecentRunHistoryView(
                    jobID: job.id,
                    loadState: historyLoadState,
                    cells: JobRunHistoryPresentation.cells(from: runs, job: job),
                    onSelect: onSelectRun
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
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
        } else if outcome == .interrupted {
            AttentionBadge(
                title: "Interrupted",
                icon: "exclamationmark.triangle.fill",
                color: .orange
            )
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
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .help("Disabled")
                .accessibilityLabel("Disabled")
        } else {
            QuietStatus(outcome: outcome)
        }
    }

    private var nextFireText: String? {
        JobNextFirePresentation.relativeText(
            for: job.schedule,
            nextFire: job.nextFireAt
        )
    }
}

private struct RecentRunHistoryView: View {
    let jobID: String
    let loadState: JobHistoryLoadState
    let cells: [JobRunHistoryCell]
    let onSelect: (JobRunSelection) -> Void

    var body: some View {
        HStack(spacing: 1) {
            content
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent run history")
        .help("Recent runs. Click a result to open details.")
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            Image(systemName: "clock")
                .frame(width: 18, height: 18)
                .accessibilityLabel("Run history not loaded")
                .help("Run history not loaded")
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Loading run history")
                .help("Loading run history")
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Run history failed to load: \(message)")
                .help("Run history failed to load: \(message)")
        case .loaded:
            if cells.isEmpty {
                Text("No runs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("No recorded runs")
                    .accessibilityLabel("No recorded runs")
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
                            .font(.system(size: 7, weight: .bold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(color(for: cell.outcome))
                            .frame(width: 14, height: 14)
                            .background(
                                color(for: cell.outcome).opacity(0.16),
                                in: Circle()
                            )
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
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
        case .interrupted:
            return .orange
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
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 120, alignment: .leading)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct QuietStatus: View {
    let outcome: Outcome

    var body: some View {
        Image(systemName: presentation.icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(presentation.color)
            .frame(width: 18, height: 18)
            .help(presentation.label)
            .accessibilityLabel(presentation.label)
    }

    private var presentation: (icon: String, label: String, color: Color) {
        switch outcome {
        case .running:
            return ("arrow.triangle.2.circlepath", "Running", .blue)
        case .interrupted:
            return ("exclamationmark.triangle.fill", "Interrupted", .orange)
        case .success:
            return ("checkmark.circle.fill", "Succeeded", .green)
        case .failure:
            return ("xmark.circle.fill", "Failed", .red)
        case .unknown:
            return ("questionmark.circle", "No run evidence", .secondary)
        }
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
