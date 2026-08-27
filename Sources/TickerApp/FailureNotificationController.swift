import AppKit
import CryptoKit
import Foundation
import TickerCore
import UserNotifications

protocol FailureNotificationHandling: AnyObject {
    func start()
    func update(
        candidates: [AttentionNotificationCandidate],
        observedIncidentIDs: [AttentionIncidentID]
    )
}

final class NoopFailureNotificationController: FailureNotificationHandling {
    func start() {}
    func update(
        candidates: [AttentionNotificationCandidate],
        observedIncidentIDs: [AttentionIncidentID]
    ) {}
}

final class FailureNotificationController:
    NSObject,
    FailureNotificationHandling,
    NSUserNotificationCenterDelegate,
    UNUserNotificationCenterDelegate
{
    static let authorizationStatusDefaultsKey = "TickerNotificationAuthorizationStatus"

    private static let modernAuthorizationRequestedDefaultsKey =
        "TickerModernNotificationAuthorizationRequested"
    private static let notifiedIncidentsDefaultsKey = "TickerNotifiedAttentionIncidents"

    private enum DeliveryMethod {
        case modern
        case legacy
        case none
    }

    private static let usesLegacyFallback =
        Bundle.main.object(forInfoDictionaryKey: "TickerAdHocSigned") as? Bool == true

    static func shouldUseLegacyFallback(
        isAdHocBuild: Bool,
        modernAuthorizationRequested: Bool
    ) -> Bool {
        isAdHocBuild && !modernAuthorizationRequested
    }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var latestCandidates: [AttentionNotificationCandidate] = []
    private var latestObservedIncidentIDs: [AttentionIncidentID] = []
    private var notifiedIncidentIDs: Set<AttentionIncidentID>
    private var pendingIncidentIDs: Set<AttentionIncidentID> = []
    private var settingsCheckInProgress = false
    private var authorizationRequestInProgress = false
    private var started = false
    private var hasReceivedJobSnapshot = false

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.notifiedIncidentsDefaultsKey),
           let decoded = try? JSONDecoder().decode([AttentionIncidentID].self, from: data) {
            notifiedIncidentIDs = Set(decoded)
        } else {
            notifiedIncidentIDs = []
        }
        super.init()
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        center.delegate = self
        if Self.usesLegacyFallback {
            NSUserNotificationCenter.default.delegate = self
        }
        checkAuthorizationAndReconcile()
    }

    func update(
        candidates: [AttentionNotificationCandidate],
        observedIncidentIDs: [AttentionIncidentID]
    ) {
        hasReceivedJobSnapshot = true
        latestCandidates = candidates
        latestObservedIncidentIDs = observedIncidentIDs
        checkAuthorizationAndReconcile()
    }

    private func checkAuthorizationAndReconcile() {
        guard !settingsCheckInProgress else {
            return
        }
        settingsCheckInProgress = true
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.settingsCheckInProgress = false
                self.defaults.set(
                    Self.authorizationStatusName(settings.authorizationStatus),
                    forKey: Self.authorizationStatusDefaultsKey
                )
                let delivery: DeliveryMethod
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    delivery = .modern
                case .notDetermined:
                    self.requestAuthorization()
                    return
                case .denied:
                    let modernAuthorizationRequested = self.defaults.bool(
                        forKey: Self.modernAuthorizationRequestedDefaultsKey
                    )
                    delivery = Self.shouldUseLegacyFallback(
                        isAdHocBuild: Self.usesLegacyFallback,
                        modernAuthorizationRequested: modernAuthorizationRequested
                    ) ? .legacy : .none
                @unknown default:
                    delivery = .none
                }
                if self.hasReceivedJobSnapshot {
                    self.reconcile(delivery: delivery)
                }
            }
        }
    }

    private func requestAuthorization() {
        guard !authorizationRequestInProgress else {
            return
        }
        defaults.set(
            true,
            forKey: Self.modernAuthorizationRequestedDefaultsKey
        )
        authorizationRequestInProgress = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.authorizationRequestInProgress = false
                self.checkAuthorizationAndReconcile()
            }
        }
    }

    private func reconcile(delivery: DeliveryMethod) {
        let plan = AttentionNotificationPlanner.plan(
            candidates: latestCandidates,
            notifiedIncidentIDs: Array(notifiedIncidentIDs),
            pendingIncidentIDs: Array(pendingIncidentIDs),
            observedIncidentIDs: latestObservedIncidentIDs
        )
        notifiedIncidentIDs = Set(plan.retainedNotifiedIncidentIDs)
        persistNotifiedIncidentIDs()

        switch delivery {
        case .none:
            return
        case .legacy:
            for candidate in plan.notifications {
                deliverLegacyNotification(for: candidate)
                notifiedIncidentIDs.insert(candidate.incidentID)
            }
            persistNotifiedIncidentIDs()
        case .modern:
            for candidate in plan.notifications {
                pendingIncidentIDs.insert(candidate.incidentID)
                center.add(notificationRequest(for: candidate)) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else {
                            return
                        }
                        self.pendingIncidentIDs.remove(candidate.incidentID)
                        guard error == nil,
                              self.latestCandidates.contains(where: {
                                  $0.incidentID == candidate.incidentID
                              }) else {
                            return
                        }
                        self.notifiedIncidentIDs.insert(candidate.incidentID)
                        self.persistNotifiedIncidentIDs()
                    }
                }
            }
        }
    }

    private func notificationRequest(
        for candidate: AttentionNotificationCandidate
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: candidate)
        content.body = notificationBody(for: candidate)
        content.sound = .default
        content.threadIdentifier = candidate.incidentID.jobID
        return UNNotificationRequest(
            identifier: notificationIdentifier(for: candidate),
            content: content,
            trigger: nil
        )
    }

    private func deliverLegacyNotification(
        for candidate: AttentionNotificationCandidate
    ) {
        let notification = NSUserNotification()
        notification.identifier = notificationIdentifier(for: candidate)
        notification.title = notificationTitle(for: candidate)
        notification.informativeText = notificationBody(for: candidate)
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func notificationTitle(
        for candidate: AttentionNotificationCandidate
    ) -> String {
        "\(candidate.jobLabel) needs attention"
    }

    private func notificationBody(
        for candidate: AttentionNotificationCandidate
    ) -> String {
        let reason = candidate.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedReason = String(reason.prefix(420))
        return "\(boundedReason)\nOpen Ticker from the menu bar to investigate."
    }

    private func notificationIdentifier(
        for candidate: AttentionNotificationCandidate
    ) -> String {
        let identity = "\(candidate.incidentID.kind.rawValue)\u{0}\(candidate.incidentID.jobID)"
        return "ticker-attention-\(Self.digest(identity))"
    }

    private func persistNotifiedIncidentIDs() {
        let sorted = notifiedIncidentIDs.sorted {
            if $0.jobID == $1.jobID {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.jobID < $1.jobID
        }
        if let data = try? JSONEncoder().encode(sorted) {
            defaults.set(data, forKey: Self.notifiedIncidentsDefaultsKey)
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func authorizationStatusName(
        _ status: UNAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined:
            return "not-determined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
