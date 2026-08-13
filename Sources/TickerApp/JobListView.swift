import AppKit
import Foundation
import SwiftUI
import TickerCore

struct JobListView: View {
    @ObservedObject var model: AppModel
    @State private var selectedJobID: String?

    private var selectedJob: Job? {
        guard let selectedJobID = selectedJobID else {
            return nil
        }
        return model.jobs.first { $0.id == selectedJobID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                sidebar
                    .frame(minWidth: 300, idealWidth: 330, maxWidth: 370)

                Group {
                    if let job = selectedJob {
                        JobDetailView(model: model, job: job)
                            .id(job.id)
                    } else {
                        EmptyJobDetailView()
                    }
                }
                .frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 780, height: 570)
        .onReceive(model.$jobs) { jobs in
            if let selectedJobID = selectedJobID,
               jobs.contains(where: { $0.id == selectedJobID }) {
                return
            }
            selectedJobID = jobs.first?.id
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ticker")
                    .font(.title2.bold())
                Spacer()
                Text("\(model.jobs.count) jobs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !model.errors.isEmpty {
                        ErrorSummaryView(errors: model.errors)
                    }

                    if model.jobs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary)
                            Text("No scheduled jobs found")
                                .font(.headline)
                            Text("Ticker checked launchd, crontab, and Claude routines.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(JobSource.allCases, id: \.rawValue) { source in
                            let sourceJobs = model.jobs.filter { $0.source == source }
                            if !sourceJobs.isEmpty {
                                JobSourceSection(
                                    source: source,
                                    jobs: sourceJobs,
                                    selectedJobID: $selectedJobID,
                                    model: model
                                )
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Refreshed")
                .foregroundColor(.secondary)
            Text(model.lastRefresh, style: .time)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 42)
    }
}

private struct JobSourceSection: View {
    let source: JobSource
    let jobs: [Job]
    @Binding var selectedJobID: String?
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(sectionTitle)
                .font(.caption.bold())
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)

            ForEach(jobs) { job in
                JobRow(
                    job: job,
                    outcome: model.outcome(for: job),
                    skipStorm: model.skipStorm(for: job),
                    selected: selectedJobID == job.id
                ) {
                    selectedJobID = job.id
                }
            }
        }
    }

    private var sectionTitle: String {
        switch source {
        case .launchd:
            return "launchd"
        case .crontab:
            return "crontab"
        case .claudeRoutine:
            return "Claude routines"
        }
    }
}

private struct JobRow: View {
    let job: Job
    let outcome: Outcome
    let skipStorm: SkipStormSummary?
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(statusText)

                    Text(job.label)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 6)
                    OutcomeChip(outcome: outcome)
                }

                HStack(spacing: 6) {
                    Text(job.schedule.humanDescription)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(relativeNextFire)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let skew = job.skew, skew > 3_600 {
                    WarningLine(
                        icon: "clock.badge.exclamationmark",
                        text: "ran \(Self.formatHours(skew)) late"
                    )
                }

                if let skipStorm = skipStorm {
                    WarningLine(icon: "exclamationmark.arrow.triangle.2.circlepath", text: skipStorm.displayText)
                }
            }
            .padding(9)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var relativeNextFire: String {
        guard let nextFire = job.nextFireAt else {
            return "on demand"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: nextFire, relativeTo: Date())
    }

    private var statusColor: Color {
        switch outcome {
        case .success:
            return .green
        case .failure:
            return .red
        case .running, .unknown:
            return .gray
        }
    }

    private var statusText: String {
        switch outcome {
        case .running:
            return "Running"
        case .success:
            return "Succeeded"
        case .failure:
            return "Failed"
        case .unknown:
            return "Unknown outcome"
        }
    }

    private static func formatHours(_ interval: TimeInterval) -> String {
        String(format: "%.1fh", interval / 3_600)
    }
}

private struct OutcomeChip: View {
    let outcome: Outcome

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var title: String {
        switch outcome {
        case .running:
            return "running"
        case .success:
            return "ok"
        case .failure:
            return "failed"
        case .unknown:
            return "unknown"
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

private struct WarningLine: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundColor(.orange)
            .lineLimit(2)
    }
}

private struct ErrorSummaryView: View {
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Some sources could not be refreshed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundColor(.red)
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Text(error)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyJobDetailView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Select a job")
                .font(.headline)
            Text("Run details and captured output appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
