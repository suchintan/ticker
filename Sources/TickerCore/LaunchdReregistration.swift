import Darwin
import Foundation

public struct LaunchdReregistrationRecord: Codable {
    public enum Status: String, Codable {
        case reregistered
        case unchanged
        case skipped
        case failed
    }

    public let jobID: String
    public let label: String
    public let status: Status
    public let reason: String?
    public let message: String?
}

public struct LaunchdReregistration {
    private let jobs: [Job]
    private let uid: UInt32
    private let launchAgentsDirectory: URL
    private let launchctl: ([String]) -> LoginItemCommandResult

    public init(jobs: [Job], uid: UInt32, launchAgentsDirectory: URL,
                launchctl: @escaping ([String]) -> LoginItemCommandResult) {
        self.jobs = jobs
        self.uid = uid
        self.launchAgentsDirectory = launchAgentsDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.launchctl = launchctl
    }

    public func recover() -> [LaunchdReregistrationRecord] {
        jobs.filter { job in
            guard job.source == .launchd, job.managed, job.launchdDomain == .userAgent,
                  job.runtimeStatusAttribution != .ambiguous,
                  job.label != RecoveryAgentController.agentLabel,
                  let path = job.configPath,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                    .deletingLastPathComponent() == launchAgentsDirectory,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let owner = attributes[.ownerAccountID] as? NSNumber else {
                return false
            }
            return owner.uint32Value == uid
        }.sorted { $0.id < $1.id }.map(reregister)
    }

    private func reregister(_ job: Job) -> LaunchdReregistrationRecord {
        var modificationTimeWarning: String?
        func record(_ status: LaunchdReregistrationRecord.Status,
                    reason: String? = nil, message: String? = nil) -> LaunchdReregistrationRecord {
            let messages = [message, modificationTimeWarning].compactMap { $0 }
            return LaunchdReregistrationRecord(jobID: job.id, label: job.label, status: status,
                                              reason: reason,
                                              message: messages.isEmpty ? nil : messages.joined(separator: " "))
        }

        guard let path = job.configPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
                as? [String: Any] else {
            return record(.skipped, reason: "plist-unreadable")
        }
        let domain = "gui/\(uid)"
        let target = "\(domain)/\(job.label)"
        let initial = launchctl(["print", target])
        guard initial.status == 0 else {
            return record(.skipped, reason: "not-loaded")
        }
        let snapshot = LaunchdRuntimeSnapshot.parse(initial.stdout)
        let trigger: String
        if snapshot.properties.contains("needs LWCR update") {
            trigger = "needs-lwcr-update"
        } else if snapshot.lastExitReason == "OS_REASON_CODESIGNING" {
            trigger = "launch-killed"
        } else {
            return record(.unchanged)
        }
        let configURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard let loadedPath = snapshot.path,
              URL(fileURLWithPath: loadedPath).resolvingSymlinksInPath().standardizedFileURL == configURL else {
            return record(.skipped, reason: "path-mismatch",
                          message: "Loaded plist path \(snapshot.path ?? "<missing>") does not match candidate plist path \(path).")
        }
        if snapshot.state == "running" || snapshot.processID != nil {
            return record(.skipped, reason: "running", message: "Trigger \(trigger): the job is running.")
        }
        if plist["RunAtLoad"] as? Bool == true {
            return record(.skipped, reason: "run-at-load",
                          message: "Trigger \(trigger): bootstrap would start this RunAtLoad job.")
        }
        if plist["KeepAlive"] as? Bool == true || plist["KeepAlive"] is [String: Any] {
            return record(.skipped, reason: "keep-alive",
                          message: "Trigger \(trigger): bootstrap would start this KeepAlive job.")
        }

        let bootout = launchctl(["bootout", target])
        if bootout.status != 0 && !RecoveryAgentController.isExactNotFound(bootout) {
            let loaded = launchctl(["print", target])
            if loaded.status == 0 {
                return record(.failed, reason: trigger,
                              message: "bootout failed (exit \(bootout.status)): \(bootout.stderr.trimmingCharacters(in: .whitespacesAndNewlines)). The job is still loaded.")
            }
        }
        if path.withCString({ Darwin.utimes($0, nil) }) != 0 {
            modificationTimeWarning = "Could not update the plist modification time (\(String(cString: strerror(errno)))); macOS may keep its old launch record."
        }
        var bootstrap = launchctl(["bootstrap", domain, path])
        for delay in [0.5, 1.0, 2.0, 4.0] {
            if bootstrap.status == 0 { break }
            Thread.sleep(forTimeInterval: delay)
            bootstrap = launchctl(["bootstrap", domain, path])
        }
        guard bootstrap.status == 0 else {
            let quotedPath = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return record(.failed, reason: trigger,
                          message: "The job is NOT loaded now. bootstrap failed after 5 attempts (exit \(bootstrap.status)): "
                            + bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                            + ". Run manually: launchctl bootstrap \(domain) \(quotedPath)")
        }
        let verification = launchctl(["print", target])
        guard verification.status == 0 else {
            return record(.failed, reason: trigger,
                          message: "Could not verify the job after bootstrap (print exit \(verification.status)): "
                            + verification.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let verifiedSnapshot = LaunchdRuntimeSnapshot.parse(verification.stdout)
        guard let verifiedPath = verifiedSnapshot.path,
              URL(fileURLWithPath: verifiedPath).resolvingSymlinksInPath().standardizedFileURL == configURL else {
            return record(.failed, reason: trigger,
                          message: "After bootstrap, loaded plist path \(verifiedSnapshot.path ?? "<missing>") does not match candidate plist path \(path).")
        }
        guard !verifiedSnapshot.properties.contains("needs LWCR update") else {
            return record(.failed, reason: trigger,
                          message: "The job still has needs LWCR update after bootstrap.")
        }
        return record(.reregistered, reason: trigger)
    }
}
