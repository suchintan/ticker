import Foundation

public struct DuplicateJobIDError: Error, LocalizedError {
    public let jobID: String
    public let firstLabel: String
    public let duplicateLabel: String

    public var errorDescription: String? {
        "Job id collision for \(jobID): '\(firstLabel)' and '\(duplicateLabel)'. Ticker kept the first discovered job."
    }
}

public struct SkipDiscoveryResult {
    public let recordsByJobID: [String: [SkipRecord]]
    public let observedJobIDs: Set<String>
    public let errors: [Error]

    public init(
        recordsByJobID: [String: [SkipRecord]],
        observedJobIDs: Set<String>,
        errors: [Error]
    ) {
        self.recordsByJobID = recordsByJobID
        self.observedJobIDs = observedJobIDs
        self.errors = errors
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

    public func skipSnapshot() -> SkipDiscoveryResult {
        var recordsByJobID: [String: [SkipRecord]] = [:]
        var observedJobIDs = Set<String>()
        var errors: [Error] = []

        for adapter in adapters {
            guard let skipSource = adapter as? SkipSourceAdapter else {
                continue
            }
            let snapshot = skipSource.skipSnapshot()
            observedJobIDs.formUnion(snapshot.observedJobIDs)
            errors.append(contentsOf: snapshot.errors)
            for (jobID, recordsForJob) in snapshot.recordsByJobID {
                recordsByJobID[jobID, default: []].append(contentsOf: recordsForJob)
            }
        }

        for jobID in Array(recordsByJobID.keys) {
            recordsByJobID[jobID]?.sort { $0.at < $1.at }
        }
        return SkipDiscoveryResult(
            recordsByJobID: recordsByJobID,
            observedJobIDs: observedJobIDs,
            errors: errors
        )
    }
}
