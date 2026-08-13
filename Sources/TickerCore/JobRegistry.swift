import Foundation

public struct DuplicateJobIDError: Error, LocalizedError {
    public let jobID: String
    public let firstLabel: String
    public let duplicateLabel: String

    public var errorDescription: String? {
        "Job id collision for \(jobID): '\(firstLabel)' and '\(duplicateLabel)'. Ticker kept the first discovered job."
    }
}

public final class JobRegistry {
    private let adapters: [JobSourceAdapter]

    public init(adapters: [JobSourceAdapter]) {
        self.adapters = adapters
    }

    public static func standard() -> JobRegistry {
        JobRegistry(
            adapters: [
                LaunchdAdapter(),
                CrontabAdapter(),
                ClaudeRoutineAdapter(),
            ]
        )
    }

    public func discoverAll() -> (jobs: [Job], errors: [Error]) {
        var jobs: [Job] = []
        var errors: [Error] = []

        for adapter in adapters {
            do {
                jobs.append(contentsOf: try adapter.discover())
            } catch {
                errors.append(error)
            }
        }

        var uniqueJobs: [Job] = []
        uniqueJobs.reserveCapacity(jobs.count)
        var jobsByID: [String: Job] = [:]
        jobsByID.reserveCapacity(jobs.count)
        for job in jobs {
            if let existing = jobsByID[job.id] {
                errors.append(
                    DuplicateJobIDError(
                        jobID: job.id,
                        firstLabel: existing.label,
                        duplicateLabel: job.label
                    )
                )
                continue
            }
            jobsByID[job.id] = job
            uniqueJobs.append(job)
        }
        jobs = uniqueJobs

        let scheduledJobs = jobs.map { (job: $0, nextFireAt: $0.nextFireAt) }
        let sortedJobs = scheduledJobs.sorted { lhs, rhs in
            switch (lhs.nextFireAt, rhs.nextFireAt) {
            case let (left?, right?):
                if left == right {
                    return lhs.job.id < rhs.job.id
                }
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.job.id < rhs.job.id
            }
        }.map(\.job)

        return (sortedJobs, errors)
    }

    public func skips() -> [String: [SkipRecord]] {
        var recordsByJobID: [String: [SkipRecord]] = [:]

        for adapter in adapters {
            guard let skipSource = adapter as? SkipSourceAdapter,
                  let records = try? skipSource.skips()
            else {
                continue
            }
            for (jobID, recordsForJob) in records {
                recordsByJobID[jobID, default: []].append(contentsOf: recordsForJob)
            }
        }

        for jobID in Array(recordsByJobID.keys) {
            recordsByJobID[jobID]?.sort { $0.at < $1.at }
        }
        return recordsByJobID
    }
}
