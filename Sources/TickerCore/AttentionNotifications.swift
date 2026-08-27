import Foundation

public enum AttentionIncidentKind: String, Codable, Hashable, Sendable {
    case brokenConfiguration
    case failedRun
    case ambiguousRuntime
    case lateRun
    case skipStorm
    case wrapperRecovery
}

public struct AttentionIncidentID: Codable, Hashable, Sendable {
    public let jobID: String
    public let kind: AttentionIncidentKind

    public init(jobID: String, kind: AttentionIncidentKind) {
        self.jobID = jobID
        self.kind = kind
    }
}

public struct AttentionNotificationCandidate: Hashable, Sendable {
    public let incidentID: AttentionIncidentID
    public let jobLabel: String
    public let reason: String

    public init(
        incidentID: AttentionIncidentID,
        jobLabel: String,
        reason: String
    ) {
        self.incidentID = incidentID
        self.jobLabel = jobLabel
        self.reason = reason
    }
}

public struct AttentionNotificationPlan: Equatable, Sendable {
    public let notifications: [AttentionNotificationCandidate]
    public let retainedNotifiedIncidentIDs: [AttentionIncidentID]

    public init(
        notifications: [AttentionNotificationCandidate],
        retainedNotifiedIncidentIDs: [AttentionIncidentID]
    ) {
        self.notifications = notifications
        self.retainedNotifiedIncidentIDs = retainedNotifiedIncidentIDs
    }
}

public enum AttentionIncidentObservationPolicy {
    public static func failedRunIsAuthoritative(
        for job: Job,
        hasScheduledHealthSnapshot: Bool
    ) -> Bool {
        hasScheduledHealthSnapshot
            || (job.source == .launchd && !job.managed && job.lastKnownExit != nil)
    }
}

public enum AttentionNotificationPlanner {
    public static func plan(
        candidates: [AttentionNotificationCandidate],
        notifiedIncidentIDs: [AttentionIncidentID],
        pendingIncidentIDs: [AttentionIncidentID],
        observedIncidentIDs: [AttentionIncidentID]
    ) -> AttentionNotificationPlan {
        let activeIncidentIDs = Set(candidates.map(\.incidentID))
        let observed = Set(observedIncidentIDs)
        let retainedNotified = Set(notifiedIncidentIDs).filter {
            !observed.contains($0) || activeIncidentIDs.contains($0)
        }
        var suppressed = Set(retainedNotified).union(pendingIncidentIDs)
        var notifications: [AttentionNotificationCandidate] = []
        notifications.reserveCapacity(candidates.count)

        for candidate in candidates where suppressed.insert(candidate.incidentID).inserted {
            notifications.append(candidate)
        }

        return AttentionNotificationPlan(
            notifications: notifications,
            retainedNotifiedIncidentIDs: retainedNotified.sorted {
                if $0.jobID == $1.jobID {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.jobID < $1.jobID
            }
        )
    }
}
