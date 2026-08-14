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

struct JobListView: View {
    @ObservedObject var model: AppModel
    @State private var selectedJobID: String?
    @State private var searchText = ""
    @AppStorage("ticker.otherJobsExpanded") private var otherJobsExpanded = false
    @AppStorage("ticker.appsExpanded") private var appsExpanded = true
    @AppStorage("ticker.packageManagersExpanded") private var packageManagersExpanded = true
    @AppStorage("ticker.systemJobsExpanded") private var systemJobsExpanded = true

    private var selectedJob: Job? {
        guard let selectedJobID else {
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
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 300, max: 310)
        } detail: {
            if let job = selectedJob {
                JobDetailView(model: model, job: job)
                    .id(job.id)
            } else {
                EmptyJobDetailView()
            }
        }
        .frame(width: 820, height: 600)
        .onReceive(model.$jobs) { jobs in
            reconcileSelection(in: visibleJobs(in: jobs))
        }
        .onChange(of: searchText) { _ in
            reconcileSelection(in: matchingJobs)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            List(selection: $selectedJobID) {
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
                Button("Quit Ticker") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("Ticker menu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var provenanceSubgroups: some View {
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
                wrapperNeedsAttention: model.wrapperNeedsAttention(job)
            )
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

    private func reconcileSelection(in visibleJobs: [Job]) {
        if let selectedJobID,
           visibleJobs.contains(where: { $0.id == selectedJobID }) {
            return
        }
        selectedJobID = visibleJobs.first(where: { $0.provenance.isYours })?.id
            ?? visibleJobs.first(where: { !$0.provenance.isConfirmedThirdParty })?.id
            ?? visibleJobs.first?.id
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                status
            }
            HStack(spacing: 4) {
                Text(job.schedule.humanDescription)
                    .lineLimit(1)
                if let nextFire = JobNextFirePresentation.relativeText(
                    for: job.schedule,
                    nextFire: job.nextFireAt
                ) {
                    Text("· next \(nextFire)")
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let evidenceText {
                    Text(evidenceText)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .help(job.label)
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
            AttentionBadge(title: "Skip storm", icon: "exclamationmark.arrow.triangle.2.circlepath", color: .orange)
        } else if job.runtimeStatusAttribution == .ambiguous {
            AttentionBadge(title: "Ambiguous", icon: "questionmark.diamond.fill", color: .orange)
        } else if wrapperNeedsAttention {
            AttentionBadge(title: "Wrapper damaged", icon: "wrench.and.screwdriver.fill", color: .orange)
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
