import Darwin
import CryptoKit
import Foundation

public struct ReloadCommands: Hashable {
    public let unload: String
    public let load: String

    public init(unload: String, load: String) {
        self.unload = unload
        self.load = load
    }
}

public struct JobWrapperError: Error, LocalizedError {
    public let message: String

    public var errorDescription: String? {
        return message
    }
}

public enum JobRecoveryState: Equatable {
    case unwrapped
    case wrappedConsistent
    case identityChanged(previousJobID: String)
    case wrappedMissingBackup
    case wrappedBackupContentMismatch
    case wrappedForeignLabel(embeddedJobID: String)
    case ambiguousTickerInvocation
    case staleManagedRow

    public static let ambiguousTickerInvocationExplanation =
        "Ticker cannot verify that this plist's command matches the authenticated backup "
        + "associated with its wrapper. Program or ProgramArguments changed, or the wrapper "
        + "and backup identify different commands. Compare those fields with the authenticated "
        + "backup, restore the intended command, then run ticker doctor."

    public var description: String {
        switch self {
        case .unwrapped:
            return "unwrapped"
        case .wrappedConsistent:
            return "wrapped-consistent"
        case .identityChanged(let previousJobID):
            return "identity-changed (\(previousJobID))"
        case .wrappedMissingBackup:
            return "wrapped-missing-backup"
        case .wrappedBackupContentMismatch:
            return "wrapped-backup-content-mismatch"
        case .wrappedForeignLabel(let embeddedJobID):
            return "wrapped-foreign-label (\(embeddedJobID))"
        case .ambiguousTickerInvocation:
            return "ambiguous-ticker-invocation"
        case .staleManagedRow:
            return "stale-row"
        }
    }
}

private struct BackupMetadata: Codable {
    let version: Int
    let jobID: String
    let sourcePlistPath: String
    let backupByteCount: Int
    let backupSHA256: String
}

private enum BackupResolution {
    case verified(URL)
    case missing
    case contentMismatch([URL])
}

private enum BackupValidation {
    case verified
    case contentMismatch
    case unrelated
}

private struct OriginalExecution: Equatable {
    let command: [String]
    let argv0: String?
}

private struct FileMetadataSnapshot: Codable, Equatable {
    let ownerID: uid_t
    let groupID: gid_t
    let mode: mode_t
    let flags: UInt32
    let aclText: String?
    let extendedAttributes: [String: Data]
}

private struct ExchangeTransactionRecord: Codable {
    let version: Int
    let destinationPath: String
    let temporaryPath: String
    let expectedDataSHA256: String
    let stagedDataSHA256: String
    let expectedMetadata: FileMetadataSnapshot
    let stagedMetadata: FileMetadataSnapshot
}

public final class JobWrapper {
    private let store: RunStore
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let immediatelyBeforeSourceExchange: (() throws -> Void)?
    private let immediatelyAfterSourceExchange: (() -> Void)?

    public init(store: RunStore) {
        self.store = store
        fileManager = .default
        backupDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        immediatelyBeforeSourceExchange = nil
        immediatelyAfterSourceExchange = nil
    }

    public init(store: RunStore, backupDirectory: URL, fileManager: FileManager = .default) {
        self.store = store
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        immediatelyBeforeSourceExchange = nil
        immediatelyAfterSourceExchange = nil
    }

    init(
        store: RunStore,
        backupDirectory: URL,
        fileManager: FileManager = .default,
        immediatelyBeforeSourceExchange: @escaping () throws -> Void,
        immediatelyAfterSourceExchange: (() -> Void)? = nil
    ) {
        self.store = store
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.immediatelyBeforeSourceExchange = immediatelyBeforeSourceExchange
        self.immediatelyAfterSourceExchange = immediatelyAfterSourceExchange
    }

    public func wrap(job: Job, tickerPath: String) throws -> ReloadCommands {
        let plistURL = try configurationURL(for: job)
        try recoverInterruptedExchange(at: plistURL)
        let commands = reloadCommands(for: plistURL)
        guard job.canRunNow else {
            throw JobWrapperError(
                message: "Cannot wrap \(job.label): "
                    + (job.runNowUnavailableReason
                        ?? "Ticker cannot faithfully reproduce its scheduled execution context.")
            )
        }
        let originalData = try readData(at: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: originalData,
                options: [],
                format: &format
            )
        } catch {
            throw JobWrapperError(
                message: "Could not parse launchd plist at \(plistURL.path): \(error.localizedDescription)"
            )
        }

        guard var dictionary = propertyList as? [String: Any] else {
            throw JobWrapperError(message: "Launchd plist at \(plistURL.path) is not a dictionary")
        }

        let decodedWrapper = (dictionary["ProgramArguments"] as? [String]).flatMap(LaunchdWrapper.decode)
        let state = try recoveryState(job: job)
        switch state {
        case .wrappedConsistent:
            try migrateManagedIdentityIfNeeded(
                job: job,
                plistURL: plistURL,
                embeddedJobID: decodedWrapper?.label
            )
            try migrateWrapperIfNeeded(
                dictionary: &dictionary,
                format: format,
                plistURL: plistURL,
                job: job,
                tickerPath: tickerPath,
                expectedSourceData: originalData
            )
            return commands
        case .identityChanged:
            return try reconcileIdentityChange(job: job, tickerPath: tickerPath)
        case .wrappedBackupContentMismatch:
            throw JobWrapperError(
                message: "Ticker backup content for \(job.id) does not match its authenticated metadata; refusing to rewrite the plist"
            )
        case .ambiguousTickerInvocation:
            if case .verified(let backupURL) = try backupResolution(for: job, plistURL: plistURL) {
                throw ownedKeyConflictError(job: job, plistURL: plistURL, backupURL: backupURL)
            }
            throw JobWrapperError(
                message: "Launchd job \(job.id) invokes an unproven executable named ticker; refusing to rewrite it"
            )
        case .wrappedForeignLabel(let embeddedJobID):
            throw JobWrapperError(
                message: "Launchd job \(job.id) contains a Ticker wrapper for \(embeddedJobID); refusing to replace it"
            )
        case .wrappedMissingBackup:
            guard let decodedWrapper, acceptedWrapperLabels(for: job).contains(decodedWrapper.label) else {
                throw JobWrapperError(message: "Could not decode the existing Ticker wrapper for \(job.id)")
            }

            if case .verified(let backupURL) = try backupResolution(for: job, plistURL: plistURL) {
                try store.markManaged(jobID: job.id, backupPath: backupURL.path)
                try claimBackupSource(backupURL: backupURL, job: job, plistURL: plistURL)
            } else {
                let repairedDictionary = try reconstructedOriginal(
                    from: dictionary,
                    decodedWrapper: decodedWrapper,
                    job: job
                )
                let repairedData = try serializedData(
                    repairedDictionary,
                    format: format,
                    plistURL: plistURL
                )
                try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                let backupURL = uniqueBackupURL(for: job)
                try persistBackupWithMetadata(
                    repairedData,
                    to: backupURL,
                    job: job,
                    plistURL: plistURL
                )
                try store.markManaged(jobID: job.id, backupPath: backupURL.path)
                try claimBackupSource(backupURL: backupURL, job: job, plistURL: plistURL)
            }

            try migrateManagedIdentityIfNeeded(
                job: job,
                plistURL: plistURL,
                embeddedJobID: decodedWrapper.label
            )
            try migrateWrapperIfNeeded(
                dictionary: &dictionary,
                format: format,
                plistURL: plistURL,
                job: job,
                tickerPath: tickerPath,
                expectedSourceData: originalData
            )
            return commands
        case .staleManagedRow:
            try store.unmarkManaged(jobID: job.id)
        case .unwrapped:
            break
        }

        let originalExecution = try execution(from: dictionary, fallback: job.command, jobID: job.id)

        do {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        } catch {
            throw JobWrapperError(
                message: "Could not create backup directory at \(backupDirectory.path): \(error.localizedDescription)"
            )
        }

        let backupURL = uniqueBackupURL(for: job)
        try persistBackupWithMetadata(
            originalData,
            to: backupURL,
            job: job,
            plistURL: plistURL
        )
        try store.markManaged(jobID: job.id, backupPath: backupURL.path)
        try claimBackupSource(backupURL: backupURL, job: job, plistURL: plistURL)

        dictionary.removeValue(forKey: "Program")
        dictionary["ProgramArguments"] = wrapperArguments(
            tickerPath: tickerPath,
            jobID: job.id,
            original: originalExecution.command,
            argv0: originalExecution.argv0
        )

        let rewrittenData: Data
        do {
            rewrittenData = try serializedData(
                dictionary,
                format: format,
                plistURL: plistURL
            )
        } catch {
            try? store.unmarkManaged(jobID: job.id)
            throw error
        }

        do {
            try writeRewrittenData(
                rewrittenData,
                to: plistURL,
                expectedSourceData: originalData
            )
        } catch {
            try? store.unmarkManaged(jobID: job.id)
            throw error
        }

        return commands
    }

    public func unwrap(job: Job) throws -> ReloadCommands {
        let plistURL = try configurationURL(for: job)
        try recoverInterruptedExchange(at: plistURL)
        let commands = reloadCommands(for: plistURL)
        let state = try recoveryState(job: job)
        switch state {
        case .wrappedConsistent:
            break
        case .identityChanged:
            throw JobWrapperError(
                message: "Launchd job \(job.id) changed identity; reconcile its history before unwrapping"
            )
        case .wrappedMissingBackup:
            guard case .verified = try backupResolution(for: job, plistURL: plistURL) else {
                throw JobWrapperError(
                    message: "Ticker recovery state for \(job.id) is incomplete; the verified backup is missing"
                )
            }
        case .wrappedBackupContentMismatch:
            throw JobWrapperError(
                message: "Ticker backup content for \(job.id) does not match its authenticated metadata; refusing to restore it"
            )
        case .ambiguousTickerInvocation:
            if case .verified(let backupURL) = try backupResolution(for: job, plistURL: plistURL) {
                throw ownedKeyConflictError(job: job, plistURL: plistURL, backupURL: backupURL)
            }
            throw JobWrapperError(
                message: "Launchd job \(job.id) invokes an unproven executable named ticker; refusing to restore it"
            )
        case .wrappedForeignLabel(let embeddedJobID):
            throw JobWrapperError(
                message: "Launchd job \(job.id) contains a Ticker wrapper for \(embeddedJobID); refusing to restore it"
            )
        case .staleManagedRow:
            throw JobWrapperError(
                message: "Launchd job \(job.id) was restored outside Ticker; clear its stale managed row before continuing"
            )
        case .unwrapped:
            throw JobWrapperError(message: "Launchd job \(job.id) is not wrapped by Ticker")
        }

        let liveData = try readData(at: plistURL)
        var liveFormat = PropertyListSerialization.PropertyListFormat.xml
        var liveDictionary = try propertyListDictionary(
            from: liveData,
            format: &liveFormat,
            plistURL: plistURL
        )
        let embeddedJobID = (liveDictionary["ProgramArguments"] as? [String])
            .flatMap(LaunchdWrapper.decode)?.label
        guard case .verified(let backupURL) = try backupResolution(
            for: job,
            plistURL: plistURL,
            embeddedJobID: embeddedJobID
        ) else {
            throw JobWrapperError(message: "No verified Ticker backup exists for \(job.id)")
        }
        let backupData = try authenticatedBackupData(
            at: backupURL,
            job: job,
            plistURL: plistURL,
            embeddedJobID: embeddedJobID
        )
        let backupDictionary = try propertyListDictionary(
            from: backupData,
            format: nil,
            plistURL: backupURL
        )
        guard wrapperMatchesBackup(
            liveDictionary: liveDictionary,
            backupDictionary: backupDictionary,
            job: job,
            acceptedLabels: embeddedJobID.map { [$0] }
                ?? acceptedWrapperLabels(for: job)
        ) else {
            throw ownedKeyConflictError(job: job, plistURL: plistURL, backupURL: backupURL)
        }

        if backupDictionary.keys.contains("Program") {
            liveDictionary["Program"] = backupDictionary["Program"]
        } else {
            liveDictionary.removeValue(forKey: "Program")
        }
        if backupDictionary.keys.contains("ProgramArguments") {
            liveDictionary["ProgramArguments"] = backupDictionary["ProgramArguments"]
        } else {
            liveDictionary.removeValue(forKey: "ProgramArguments")
        }
        try writeRewrittenData(
            try serializedData(liveDictionary, format: liveFormat, plistURL: plistURL),
            to: plistURL,
            expectedSourceData: liveData
        )

        try store.unmarkManaged(jobID: job.id)
        if let embeddedJobID, embeddedJobID != job.id {
            try store.unmarkManaged(jobID: embeddedJobID)
        }
        return commands
    }

    public func reconcileIdentityChange(job: Job, tickerPath: String) throws -> ReloadCommands {
        let plistURL = try configurationURL(for: job)
        let originalData = try readData(at: plistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        var dictionary = try propertyListDictionary(
            from: originalData,
            format: &format,
            plistURL: plistURL
        )
        guard case .identityChanged(let previousJobID) = try recoveryState(job: job),
              let arguments = dictionary["ProgramArguments"] as? [String],
              let decoded = LaunchdWrapper.decode(arguments),
              decoded.label == previousJobID else {
            throw JobWrapperError(
                message: "Launchd job \(job.id) has no authenticated identity change to reconcile"
            )
        }

        try migrateManagedIdentityIfNeeded(
            job: job,
            plistURL: plistURL,
            embeddedJobID: previousJobID
        )
        try migrateWrapperIfNeeded(
            dictionary: &dictionary,
            format: format,
            plistURL: plistURL,
            job: job,
            tickerPath: tickerPath,
            expectedSourceData: originalData
        )
        return reloadCommands(for: plistURL)
    }

    public func recoveryState(job: Job) throws -> JobRecoveryState {
        let plistURL = try configurationURL(for: job)
        try recoverInterruptedExchange(at: plistURL)
        let data = try readData(at: plistURL)
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw JobWrapperError(
                message: "Could not parse launchd plist at \(plistURL.path): \(error.localizedDescription)"
            )
        }
        guard let dictionary = propertyList as? [String: Any] else {
            throw JobWrapperError(message: "Launchd plist at \(plistURL.path) is not a dictionary")
        }

        let managedIDs = try store.managedJobIDs()
        let managedRowExists = managedIDs.contains(job.id)
        let arguments = dictionary["ProgramArguments"] as? [String]
        let acceptedLabels = acceptedWrapperLabels(for: job)
        if let arguments, let decoded = LaunchdWrapper.decode(arguments) {
            if !acceptedLabels.contains(decoded.label) {
                guard case .verified(let backupURL) = try backupResolution(
                    for: job,
                    plistURL: plistURL,
                    embeddedJobID: decoded.label
                ) else {
                    return .wrappedForeignLabel(embeddedJobID: decoded.label)
                }
                let backupDictionary = try authenticatedBackupDictionary(
                    at: backupURL,
                    job: job,
                    plistURL: plistURL,
                    embeddedJobID: decoded.label
                )
                let matches = wrapperMatchesBackup(
                    liveDictionary: dictionary,
                    backupDictionary: backupDictionary,
                    job: job,
                    acceptedLabels: [decoded.label]
                )
                return matches
                    ? .identityChanged(previousJobID: decoded.label)
                    : .ambiguousTickerInvocation
            }
            if !managedRowExists {
                guard case .verified(let backupURL) = try backupResolution(
                    for: job,
                    plistURL: plistURL,
                    embeddedJobID: decoded.label
                ),
                      let metadataData = try? Data(contentsOf: metadataURL(for: backupURL)),
                      let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: metadataData),
                      managedIDs.contains(metadata.jobID) else {
                    return .wrappedMissingBackup
                }
            }
            switch try backupResolution(
                for: job,
                plistURL: plistURL,
                embeddedJobID: decoded.label
            ) {
            case .verified(let backupURL):
                let backupDictionary = try authenticatedBackupDictionary(
                    at: backupURL,
                    job: job,
                    plistURL: plistURL,
                    embeddedJobID: decoded.label
                )
                let matches = wrapperMatchesBackup(
                    liveDictionary: dictionary,
                    backupDictionary: backupDictionary,
                    job: job
                )
                if matches, decoded.label != job.id {
                    return .identityChanged(previousJobID: decoded.label)
                }
                return matches ? .wrappedConsistent : .ambiguousTickerInvocation
            case .missing:
                return .wrappedMissingBackup
            case .contentMismatch:
                return .wrappedBackupContentMismatch
            }
        }

        guard managedRowExists else {
            return .unwrapped
        }
        switch try backupResolution(for: job, plistURL: plistURL) {
        case .verified(let backupURL):
            let backupDictionary = try authenticatedBackupDictionary(
                at: backupURL,
                job: job,
                plistURL: plistURL
            )
            return ownedCommandKeysMatch(dictionary, backupDictionary)
                ? .staleManagedRow
                : .ambiguousTickerInvocation
        case .contentMismatch:
            return .wrappedBackupContentMismatch
        case .missing:
            return .staleManagedRow
        }
    }

    public func isWrapped(job: Job) -> Bool {
        return (try? recoveryState(job: job)) == .wrappedConsistent
    }

    private func configurationURL(for job: Job) throws -> URL {
        guard job.source == .launchd else {
            throw JobWrapperError(message: "Only launchd jobs can be wrapped; \(job.id) is \(job.source.rawValue)")
        }
        guard let configPath = job.configPath, !configPath.isEmpty else {
            throw JobWrapperError(message: "Launchd job \(job.id) has no plist path")
        }
        return URL(fileURLWithPath: configPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func reloadCommands(for plistURL: URL) -> ReloadCommands {
        let path = shellQuoted(plistURL.path)
        return ReloadCommands(
            unload: "launchctl unload \(path)",
            load: "launchctl load \(path)"
        )
    }

    private func backupResolution(
        for job: Job,
        plistURL: URL,
        embeddedJobID: String? = nil
    ) throws -> BackupResolution {
        var candidates: [URL] = []
        var seenPaths = Set<String>()
        func appendCandidate(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seenPaths.insert(standardized.path).inserted {
                candidates.append(standardized)
            }
        }

        if let sqliteStore = store as? SQLiteRunStore,
           let path = try sqliteStore.managedBackupPath(jobID: job.id) {
            let storedURL = URL(fileURLWithPath: path).standardizedFileURL
            if fileManager.fileExists(atPath: storedURL.path) {
                switch try backupValidation(
                    backupURL: storedURL,
                    job: job,
                    plistURL: plistURL,
                    embeddedJobID: embeddedJobID
                ) {
                case .verified:
                    return .verified(storedURL)
                case .contentMismatch:
                    return .contentMismatch([storedURL])
                case .unrelated:
                    break
                }
            }
        }

        if let embeddedJobID,
           let sqliteStore = store as? SQLiteRunStore,
           let path = try sqliteStore.managedBackupPath(jobID: embeddedJobID) {
            let storedURL = URL(fileURLWithPath: path)
            if fileManager.fileExists(atPath: storedURL.path) {
                appendCandidate(storedURL)
            }
        }

        if fileManager.fileExists(atPath: backupDirectory.path) {
            do {
                let currentPrefix = backupStem(for: job) + ".plist."
                for candidate in try fileManager.contentsOfDirectory(
                    at: backupDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) {
                    let name = candidate.lastPathComponent
                    guard !name.hasSuffix(".metadata.json"),
                          embeddedJobID != nil
                            || name.hasPrefix(currentPrefix) else {
                        continue
                    }
                    appendCandidate(candidate)
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // A concurrent cleanup is the same as finding no directory.
            } catch {
                throw JobWrapperError(
                    message: "Could not inspect backup directory at \(backupDirectory.path): \(error.localizedDescription)"
                )
            }
        }

        var verified: [URL] = []
        var mismatched: [URL] = []
        for candidate in candidates {
            switch try backupValidation(
                backupURL: candidate,
                job: job,
                plistURL: plistURL,
                embeddedJobID: embeddedJobID
            ) {
            case .verified:
                verified.append(candidate)
            case .contentMismatch:
                mismatched.append(candidate)
            case .unrelated:
                continue
            }
        }
        if let newest = newestBackup(in: verified) {
            return .verified(newest)
        }
        if !mismatched.isEmpty {
            return .contentMismatch(mismatched)
        }
        return .missing
    }

    private func migrateManagedIdentityIfNeeded(
        job: Job,
        plistURL: URL,
        embeddedJobID: String?
    ) throws {
        guard case .verified(let backupURL) = try backupResolution(
            for: job,
            plistURL: plistURL,
            embeddedJobID: embeddedJobID
        ),
              let metadataData = try? Data(contentsOf: metadataURL(for: backupURL)),
              let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: metadataData),
              let sqliteStore = store as? SQLiteRunStore,
              let claim = try sqliteStore.backupSourceClaim(backupPath: backupURL.path),
              let embeddedJobID else {
            return
        }
        let canonicalMetadataID = try store.canonicalJobID(metadata.jobID)
        let canonicalEmbeddedID = try store.canonicalJobID(embeddedJobID)
        let canonicalClaimID = try store.canonicalJobID(claim.jobID)
        guard canonicalMetadataID == canonicalEmbeddedID,
              canonicalMetadataID == canonicalClaimID else {
            throw JobWrapperError(
                message: "Ticker backup \(backupURL.path) has conflicting identity claims; refusing reconciliation"
            )
        }
        let currentPath = canonicalPath(plistURL)
        let canonicalJobID = try store.canonicalJobID(job.id)
        guard canonicalClaimID != canonicalJobID
                || claim.sourcePlistPath != currentPath else {
            return
        }
        let claimants = try identityClaimants(
            job: job,
            plistURL: plistURL,
            metadata: metadata,
            claim: claim,
            canonicalIdentity: canonicalClaimID
        )
        guard claimants == [currentPath] else {
            throw JobWrapperError(
                message: "Ticker found \(claimants.count) extant plists that can claim the same history identity: "
                    + claimants.joined(separator: ", ")
                    + ". Keep exactly the intended plist, restore or remove the other copies manually, "
                    + "reload launchd as needed, then run ticker doctor and retry reconciliation."
            )
        }
        try sqliteStore.reconcileJobIdentity(
            from: canonicalClaimID,
            to: job.id,
            backupPath: backupURL.path,
            sourcePlistPath: currentPath
        )
    }

    private func claimBackupSource(backupURL: URL, job: Job, plistURL: URL) throws {
        guard let sqliteStore = store as? SQLiteRunStore else {
            return
        }
        try sqliteStore.claimBackupSource(
            backupPath: backupURL.path,
            jobID: job.id,
            sourcePlistPath: canonicalPath(plistURL)
        )
    }

    private func identityClaimants(
        job: Job,
        plistURL: URL,
        metadata: BackupMetadata,
        claim: BackupSourceClaim,
        canonicalIdentity: String
    ) throws -> [String] {
        let live = try propertyListDictionary(from: readData(at: plistURL), format: nil,
                                              plistURL: plistURL)
        guard let expected = (live["ProgramArguments"] as? [String]).flatMap(LaunchdWrapper.decode)
        else { return [] }
        let home = fileManager.homeDirectoryForCurrentUser
        let directories = [
            plistURL.deletingLastPathComponent(),
            URL(fileURLWithPath: claim.sourcePlistPath).deletingLastPathComponent(),
            URL(fileURLWithPath: metadata.sourcePlistPath).deletingLastPathComponent(),
            home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
        ]
        var seenDirectories = Set<String>()
        var claimants = Set<String>()
        for directory in directories {
            let canonicalDirectory = canonicalPath(directory)
            guard seenDirectories.insert(canonicalDirectory).inserted,
                  let entries = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for candidate in entries where candidate.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: candidate),
                      let dictionary = try? propertyListDictionary(
                        from: data,
                        format: nil,
                        plistURL: candidate
                      ),
                      let arguments = dictionary["ProgramArguments"] as? [String],
                      let decoded = LaunchdWrapper.decode(arguments),
                      try store.canonicalJobID(decoded.label) == canonicalIdentity,
                      decoded.original == expected.original,
                      decoded.argv0 == expected.argv0 else {
                    continue
                }
                claimants.insert(canonicalPath(candidate))
            }
        }
        return claimants.sorted()
    }

    private func newestBackup(in candidates: [URL]) -> URL? {
        candidates.max { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date.distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date.distantPast
            return leftDate < rightDate
        }
    }

    private func uniqueBackupURL(for job: Job) -> URL {
        let epoch = Int64(Date().timeIntervalSince1970 * 1_000)
        return backupDirectory.appendingPathComponent(
            "\(backupStem(for: job)).plist.\(epoch).\(UUID().uuidString)",
            isDirectory: false
        )
    }

    private func backupStem(for job: Job) -> String {
        let digest = SHA256.hash(data: Data(job.id.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(sanitizedLabel(String(job.label.prefix(80)))).\(digest)"
    }

    private func sanitizedLabel(_ label: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        return label.components(separatedBy: forbidden).joined(separator: "_")
    }

    private func metadataURL(for backupURL: URL) -> URL {
        backupURL.appendingPathExtension("metadata.json")
    }

    private func backupValidation(
        backupURL: URL,
        job: Job,
        plistURL: URL,
        embeddedJobID: String?
    ) throws -> BackupValidation {
        guard let metadataData = try? Data(contentsOf: metadataURL(for: backupURL)),
              let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: metadataData),
              let backupData = try? Data(contentsOf: backupURL) else {
            return .contentMismatch
        }
        return try backupValidation(
            metadata: metadata,
            backupData: backupData,
            job: job,
            plistURL: plistURL,
            backupURL: backupURL,
            embeddedJobID: embeddedJobID
        )
    }

    private func backupValidation(
        metadata: BackupMetadata,
        backupData: Data,
        job: Job,
        plistURL: URL,
        backupURL: URL,
        embeddedJobID: String?
    ) throws -> BackupValidation {
        guard metadata.version == 2 else {
            return .contentMismatch
        }

        let currentIdentityMatches = metadata.jobID == job.id
            && metadata.sourcePlistPath == canonicalPath(plistURL)
        let historicalIdentityMatches = try authenticatedSourceTransition(
            metadata: metadata,
            backupData: backupData,
            backupURL: backupURL,
            job: job,
            plistURL: plistURL,
            embeddedJobID: embeddedJobID
        )
        guard currentIdentityMatches || historicalIdentityMatches else {
            return .unrelated
        }
        guard backupData.count == metadata.backupByteCount,
              sha256(backupData) == metadata.backupSHA256 else {
            return .contentMismatch
        }
        return .verified
    }

    private func authenticatedSourceTransition(
        metadata: BackupMetadata,
        backupData: Data,
        backupURL: URL,
        job: Job,
        plistURL: URL,
        embeddedJobID: String?
    ) throws -> Bool {
        guard let embeddedJobID,
              let sqliteStore = store as? SQLiteRunStore,
              let claim = try sqliteStore.backupSourceClaim(backupPath: backupURL.path) else {
            return false
        }

        let canonicalMetadataID = try store.canonicalJobID(metadata.jobID)
        guard try store.canonicalJobID(embeddedJobID) == canonicalMetadataID,
              try store.canonicalJobID(claim.jobID) == canonicalMetadataID else {
            return false
        }

        let storedPaths = [
            try sqliteStore.managedBackupPath(jobID: metadata.jobID),
            try sqliteStore.managedBackupPath(jobID: job.id),
        ].compactMap { $0 }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard storedPaths.contains(backupURL.standardizedFileURL.path) else {
            return false
        }

        guard let backupDictionary = try? propertyListDictionary(
            from: backupData,
            format: nil,
            plistURL: backupURL
        ),
              let originalLabel = backupDictionary["Label"] as? String,
              canonicalLaunchdJobID(
                label: originalLabel,
                configPath: metadata.sourcePlistPath
              ) == metadata.jobID else {
            return false
        }

        let currentPath = canonicalPath(plistURL)
        if claim.sourcePlistPath == currentPath {
            return true
        }
        return !fileManager.fileExists(atPath: claim.sourcePlistPath)
    }

    private func authenticatedBackupData(
        at backupURL: URL,
        job: Job,
        plistURL: URL,
        embeddedJobID: String? = nil
    ) throws -> Data {
        let metadataData = try readData(at: metadataURL(for: backupURL))
        let backupData = try readData(at: backupURL)
        let metadata: BackupMetadata
        do {
            metadata = try JSONDecoder().decode(BackupMetadata.self, from: metadataData)
        } catch {
            throw JobWrapperError(
                message: "Backup metadata at \(metadataURL(for: backupURL).path) is not authenticated"
            )
        }
        switch try backupValidation(
            metadata: metadata,
            backupData: backupData,
            job: job,
            plistURL: plistURL,
            backupURL: backupURL,
            embeddedJobID: embeddedJobID
        ) {
        case .verified:
            return backupData
        case .contentMismatch:
            throw JobWrapperError(
                message: "Backup content at \(backupURL.path) changed after it was recorded; refusing to restore it"
            )
        case .unrelated:
            throw JobWrapperError(
                message: "Backup metadata at \(metadataURL(for: backupURL).path) belongs to another launchd source"
            )
        }
    }

    private func authenticatedBackupDictionary(
        at backupURL: URL,
        job: Job,
        plistURL: URL,
        embeddedJobID: String? = nil
    ) throws -> [String: Any] {
        try propertyListDictionary(
            from: authenticatedBackupData(
                at: backupURL,
                job: job,
                plistURL: plistURL,
                embeddedJobID: embeddedJobID
            ),
            format: nil,
            plistURL: backupURL
        )
    }

    private func propertyListDictionary(
        from data: Data,
        format: UnsafeMutablePointer<PropertyListSerialization.PropertyListFormat>?,
        plistURL: URL
    ) throws -> [String: Any] {
        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: format
            )
        } catch {
            throw JobWrapperError(
                message: "Could not parse launchd plist at \(plistURL.path): \(error.localizedDescription)"
            )
        }
        guard let dictionary = propertyList as? [String: Any] else {
            throw JobWrapperError(message: "Launchd plist at \(plistURL.path) is not a dictionary")
        }
        return dictionary
    }

    private func wrapperMatchesBackup(
        liveDictionary: [String: Any],
        backupDictionary: [String: Any],
        job: Job,
        acceptedLabels: Set<String>? = nil
    ) -> Bool {
        guard !liveDictionary.keys.contains("Program"),
              let arguments = liveDictionary["ProgramArguments"] as? [String],
              let decoded = LaunchdWrapper.decode(arguments),
              (acceptedLabels ?? acceptedWrapperLabels(for: job)).contains(decoded.label),
              let originalExecution = try? execution(
                  from: backupDictionary,
                  fallback: job.command,
                  jobID: job.id
              ) else {
            return false
        }
        return decoded.original == originalExecution.command
            && decoded.argv0 == originalExecution.argv0
    }

    private func ownedCommandKeysMatch(
        _ liveDictionary: [String: Any],
        _ backupDictionary: [String: Any]
    ) -> Bool {
        let liveHasProgram = liveDictionary.keys.contains("Program")
        let backupHasProgram = backupDictionary.keys.contains("Program")
        guard liveHasProgram == backupHasProgram,
              !liveHasProgram
                || (liveDictionary["Program"] as? String) == (backupDictionary["Program"] as? String)
        else {
            return false
        }

        let liveHasArguments = liveDictionary.keys.contains("ProgramArguments")
        let backupHasArguments = backupDictionary.keys.contains("ProgramArguments")
        guard liveHasArguments == backupHasArguments,
              !liveHasArguments
                || (liveDictionary["ProgramArguments"] as? [String])
                    == (backupDictionary["ProgramArguments"] as? [String])
        else {
            return false
        }
        return true
    }

    private func ownedKeyConflictError(
        job: Job,
        plistURL: URL,
        backupURL: URL
    ) -> JobWrapperError {
        JobWrapperError(
            message: "Cannot safely restore \(plistURL.path) because Program or ProgramArguments "
                + "changed after Ticker wrapped the job. Ticker did not modify the plist. "
                + "Compare those keys with the authenticated backup at \(backupURL.path), "
                + "restore the intended command manually, and then run ticker doctor."
        )
    }

    private func ensureSourceUnchanged(_ expectedData: Data, at plistURL: URL) throws {
        guard try readData(at: plistURL) == expectedData else {
            throw JobWrapperError(
                message: "Launchd plist at \(plistURL.path) changed while Ticker was preparing "
                    + "to rewrite it. Ticker did not modify the plist. Review the current file and retry."
            )
        }
    }

    private func persistBackupWithMetadata(
        _ data: Data,
        to backupURL: URL,
        job: Job,
        plistURL: URL
    ) throws {
        try persistBackup(data, to: backupURL)
        let metadata = BackupMetadata(
            version: 2,
            jobID: job.id,
            sourcePlistPath: canonicalPath(plistURL),
            backupByteCount: data.count,
            backupSHA256: sha256(data)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try persistBackup(try encoder.encode(metadata), to: metadataURL(for: backupURL))
        } catch {
            try? fileManager.removeItem(at: backupURL)
            throw error
        }
    }


    private func execution(
        from dictionary: [String: Any],
        fallback: [String],
        jobID: String
    ) throws -> OriginalExecution {
        if let program = dictionary["Program"] as? String, !program.isEmpty {
            let programArguments = dictionary["ProgramArguments"] as? [String]
            if let programArguments, !programArguments.isEmpty {
                return OriginalExecution(
                    command: [program] + Array(programArguments.dropFirst()),
                    argv0: programArguments[0]
                )
            }
            return OriginalExecution(command: [program], argv0: program)
        }
        if let arguments = dictionary["ProgramArguments"] as? [String], !arguments.isEmpty {
            return OriginalExecution(command: arguments, argv0: nil)
        }
        if !fallback.isEmpty {
            return OriginalExecution(command: fallback, argv0: nil)
        }
        throw JobWrapperError(message: "Launchd job \(jobID) has no command to wrap")
    }

    private func reconstructedOriginal(
        from dictionary: [String: Any],
        decodedWrapper: (label: String, original: [String], argv0: String?),
        job: Job
    ) throws -> [String: Any] {
        guard !decodedWrapper.original.isEmpty else {
            throw JobWrapperError(message: "Ticker wrapper for \(job.id) has no child command")
        }
        var restored = dictionary
        if let argv0 = decodedWrapper.argv0 {
            restored["Program"] = decodedWrapper.original[0]
            restored["ProgramArguments"] = [argv0] + Array(decodedWrapper.original.dropFirst())
        } else {
            restored.removeValue(forKey: "Program")
            restored["ProgramArguments"] = decodedWrapper.original
        }
        return restored
    }

    private func migrateWrapperIfNeeded(
        dictionary: inout [String: Any],
        format: PropertyListSerialization.PropertyListFormat,
        plistURL: URL,
        job: Job,
        tickerPath: String,
        expectedSourceData: Data
    ) throws {
        guard let arguments = dictionary["ProgramArguments"] as? [String],
              let decoded = LaunchdWrapper.decode(arguments) else {
            return
        }
        let expected = wrapperArguments(
            tickerPath: tickerPath,
            jobID: job.id,
            original: decoded.original,
            argv0: decoded.argv0
        )
        guard arguments != expected else {
            return
        }
        dictionary["ProgramArguments"] = expected
        try writeRewrittenData(
            try serializedData(dictionary, format: format, plistURL: plistURL),
            to: plistURL,
            expectedSourceData: expectedSourceData
        )
    }

    private func wrapperArguments(
        tickerPath: String,
        jobID: String,
        original: [String],
        argv0: String?
    ) -> [String] {
        var arguments = [
            tickerPath,
            "run",
            "--ticker-wrapper-version",
            LaunchdWrapper.currentVersion,
            "--label",
            jobID,
        ]
        if let argv0 {
            arguments += ["--argv0", argv0]
        }
        arguments += ["--"] + original
        return arguments
    }

    private func acceptedWrapperLabels(for job: Job) -> Set<String> {
        [job.id]
    }

    private func canonicalPath(_ url: URL) -> String {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func canonicalLaunchdJobID(label: String, configPath: String) -> String {
        let digest = SHA256.hash(data: Data(configPath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "launchd:\(label)#\(digest.prefix(12))"
    }

    private func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func persistBackup(_ data: Data, to backupURL: URL) throws {
        try atomicWrite(
            data,
            to: backupURL,
            preservingMetadataFrom: nil,
            expectedDestinationData: nil,
            beforeReplace: nil
        )
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw posixError("open directory at \(directory.path)")
        }
        defer { _ = Darwin.close(descriptor) }
        try fullySync(descriptor, description: "directory at \(directory.path)")
    }

    private func fullySync(_ descriptor: Int32, description: String) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 {
            return
        }
        if Darwin.fsync(descriptor) == 0 {
            return
        }
        throw posixError("sync \(description)")
    }

    private func posixError(_ operation: String) -> JobWrapperError {
        JobWrapperError(
            message: "Could not \(operation): \(String(cString: strerror(errno)))"
        )
    }

    private func serializedData(
        _ dictionary: [String: Any],
        format: PropertyListSerialization.PropertyListFormat,
        plistURL: URL
    ) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: format,
                options: 0
            )
        } catch {
            throw JobWrapperError(
                message: "Could not serialize launchd plist at \(plistURL.path): \(error.localizedDescription)"
            )
        }
    }

    private func writeRewrittenData(
        _ data: Data,
        to plistURL: URL,
        expectedSourceData: Data
    ) throws {
        try atomicWrite(
            data,
            to: plistURL,
            preservingMetadataFrom: plistURL,
            expectedDestinationData: expectedSourceData,
            beforeReplace: immediatelyBeforeSourceExchange
        )
    }

    private func atomicWrite(
        _ data: Data,
        to destinationURL: URL,
        preservingMetadataFrom metadataSourceURL: URL?,
        expectedDestinationData: Data?,
        beforeReplace: (() throws -> Void)?
    ) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let expectedDestinationMetadata = try expectedDestinationData.map { _ in
            try metadataSnapshot(at: destinationURL)
        }
        let temporaryURL = directory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw posixError("create temporary file at \(temporaryURL.path)")
        }

        var fileDescriptor: Int32? = descriptor
        var temporaryFileExists = true
        var transactionURL: URL?
        defer {
            if let fileDescriptor {
                _ = Darwin.close(fileDescriptor)
            }
            if temporaryFileExists {
                try? fileManager.removeItem(at: temporaryURL)
            }
            if let transactionURL {
                try? fileManager.removeItem(at: transactionURL)
            }
        }

        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 && errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw posixError("write temporary file at \(temporaryURL.path)")
                }
                offset += result
            }
        }

        if let metadataSourceURL {
            let metadataResult = metadataSourceURL.path.withCString { source in
                temporaryURL.path.withCString { destination in
                    copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_METADATA))
                }
            }
            guard metadataResult == 0 else {
                throw posixError("preserve metadata for \(metadataSourceURL.path)")
            }
        }
        try fullySync(descriptor, description: "temporary file at \(temporaryURL.path)")
        guard Darwin.close(descriptor) == 0 else {
            throw posixError("close temporary file at \(temporaryURL.path)")
        }
        fileDescriptor = nil
        let stagedMetadata = try metadataSnapshot(at: temporaryURL)

        if let expectedDestinationData {
            try ensureSourceUnchanged(expectedDestinationData, at: destinationURL)
            if let expectedDestinationMetadata {
                try ensureMetadataUnchanged(expectedDestinationMetadata, at: destinationURL)
                let recordURL = exchangeTransactionURL(for: destinationURL)
                try persistExchangeTransaction(
                    ExchangeTransactionRecord(
                        version: 1,
                        destinationPath: canonicalPath(destinationURL),
                        temporaryPath: canonicalPath(temporaryURL),
                        expectedDataSHA256: sha256(expectedDestinationData),
                        stagedDataSHA256: sha256(data),
                        expectedMetadata: expectedDestinationMetadata,
                        stagedMetadata: stagedMetadata
                    ),
                    to: recordURL
                )
                transactionURL = recordURL
            }
            try beforeReplace?()
            try exchangeAndVerify(
                temporaryURL: temporaryURL,
                destinationURL: destinationURL,
                stagedData: data,
                expectedDestinationData: expectedDestinationData,
                stagedMetadata: stagedMetadata,
                expectedDestinationMetadata: expectedDestinationMetadata,
                temporaryFileExists: &temporaryFileExists
            )
        } else {
            try beforeReplace?()
            let renameResult = temporaryURL.path.withCString { source in
                destinationURL.path.withCString { destination in
                    Darwin.renamex_np(source, destination, UInt32(RENAME_EXCL))
                }
            }
            guard renameResult == 0 else {
                throw posixError("rename temporary file into place at \(destinationURL.path)")
            }
            temporaryFileExists = false
        }
        try syncDirectory(directory)
        if let completedTransactionURL = transactionURL {
            try fileManager.removeItem(at: completedTransactionURL)
            transactionURL = nil
            try syncDirectory(directory)
        }
    }

    private func exchangeAndVerify(
        temporaryURL: URL,
        destinationURL: URL,
        stagedData: Data,
        expectedDestinationData: Data,
        stagedMetadata: FileMetadataSnapshot,
        expectedDestinationMetadata: FileMetadataSnapshot?,
        temporaryFileExists: inout Bool
    ) throws {
        guard exchange(temporaryURL, destinationURL) == 0 else {
            throw posixError("exchange temporary file into place at \(destinationURL.path)")
        }
        immediatelyAfterSourceExchange?()

        let displacedData: Data
        let displacedMetadata: FileMetadataSnapshot
        do {
            displacedData = try readData(at: temporaryURL)
            displacedMetadata = try metadataSnapshot(at: temporaryURL)
        } catch {
            guard exchange(temporaryURL, destinationURL) == 0 else {
                temporaryFileExists = false
                throw JobWrapperError(
                    message: "Ticker exchanged the launchd plist at \(destinationURL.path) but could not "
                        + "verify or restore it. The displaced bytes remain at \(temporaryURL.path)."
                )
            }
            try syncDirectory(destinationURL.deletingLastPathComponent())
            throw error
        }
        guard displacedData == expectedDestinationData,
              expectedDestinationMetadata.map({ displacedMetadata == $0 }) == true else {
            try restoreAfterChangedDestination(
                temporaryURL: temporaryURL,
                destinationURL: destinationURL,
                stagedData: stagedData,
                stagedMetadata: stagedMetadata,
                temporaryFileExists: &temporaryFileExists
            )
            throw sourceChangedError(at: destinationURL)
        }
        do {
            try fileManager.removeItem(at: temporaryURL)
            temporaryFileExists = false
        } catch {
            throw JobWrapperError(
                message: "Could not remove exchanged source bytes at \(temporaryURL.path): "
                    + error.localizedDescription
            )
        }
    }

    private func restoreAfterChangedDestination(
        temporaryURL: URL,
        destinationURL: URL,
        stagedData: Data,
        stagedMetadata: FileMetadataSnapshot,
        temporaryFileExists: inout Bool
    ) throws {
        guard exchange(temporaryURL, destinationURL) == 0 else {
            temporaryFileExists = false
            throw JobWrapperError(
                message: "Launchd plist at \(destinationURL.path) changed while Ticker was replacing it, "
                + "and Ticker could not restore the displaced bytes. They remain at \(temporaryURL.path)."
            )
        }
        try syncDirectory(destinationURL.deletingLastPathComponent())

        let replacedDuringVerification = try readData(at: temporaryURL)
        let metadataDuringVerification = try metadataSnapshot(at: temporaryURL)
        guard replacedDuringVerification != stagedData
                || metadataDuringVerification != stagedMetadata else {
            return
        }

        guard exchange(temporaryURL, destinationURL) == 0 else {
            temporaryFileExists = false
            throw JobWrapperError(
                message: "Launchd plist at \(destinationURL.path) changed again while Ticker was restoring it. "
                + "The later bytes remain at \(temporaryURL.path)."
            )
        }
        temporaryFileExists = false
        try? syncDirectory(destinationURL.deletingLastPathComponent())
        throw JobWrapperError(
            message: "Launchd plist at \(destinationURL.path) changed repeatedly while Ticker was replacing it. "
                + "Ticker preserved the displaced version at \(temporaryURL.path); review both files before retrying."
        )
    }

    private func exchange(_ firstURL: URL, _ secondURL: URL) -> Int32 {
        firstURL.path.withCString { first in
            secondURL.path.withCString { second in
                Darwin.renamex_np(first, second, UInt32(RENAME_SWAP))
            }
        }
    }

    private func exchangeTransactionURL(for destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).ticker-exchange.\(UUID().uuidString).json",
            isDirectory: false
        )
    }

    private func persistExchangeTransaction(
        _ record: ExchangeTransactionRecord,
        to url: URL
    ) throws {
        let data = try JSONEncoder().encode(record)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw posixError("create exchange transaction at \(url.path)")
        }
        var closed = false
        var completed = false
        defer {
            if !closed {
                _ = Darwin.close(descriptor)
            }
            if !completed {
                try? fileManager.removeItem(at: url)
            }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if result < 0 && errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw posixError("write exchange transaction at \(url.path)")
                }
                offset += result
            }
        }
        try fullySync(descriptor, description: "exchange transaction at \(url.path)")
        guard Darwin.close(descriptor) == 0 else {
            throw posixError("close exchange transaction at \(url.path)")
        }
        closed = true
        try syncDirectory(url.deletingLastPathComponent())
        completed = true
    }

    private func recoverInterruptedExchange(at destinationURL: URL) throws {
        let directory = destinationURL.deletingLastPathComponent()
        let prefix = ".\(destinationURL.lastPathComponent).ticker-exchange."
        let records: [URL]
        do {
            records = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ).filter {
                $0.lastPathComponent.hasPrefix(prefix)
                    && $0.pathExtension == "json"
            }.sorted { $0.path < $1.path }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }

        for recordURL in records {
            let record: ExchangeTransactionRecord
            do {
                record = try JSONDecoder().decode(
                    ExchangeTransactionRecord.self,
                    from: Data(contentsOf: recordURL)
                )
            } catch {
                throw JobWrapperError(
                    message: "Ticker found an unreadable interrupted-exchange record at "
                        + "\(recordURL.path). Preserve it and inspect the plist before retrying."
                )
            }
            guard record.version == 1,
                  record.destinationPath == canonicalPath(destinationURL) else {
                throw JobWrapperError(
                    message: "Ticker found an invalid interrupted-exchange record at "
                        + "\(recordURL.path). Preserve it and inspect the plist before retrying."
                )
            }

            let temporaryURL = URL(fileURLWithPath: record.temporaryPath).standardizedFileURL
            let expectedTemporaryPrefix = ".\(destinationURL.lastPathComponent)."
            guard temporaryURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  temporaryURL.lastPathComponent.hasPrefix(expectedTemporaryPrefix),
                  temporaryURL.lastPathComponent.hasSuffix(".tmp") else {
                throw JobWrapperError(
                    message: "Ticker refused an interrupted-exchange record with an unsafe temporary path at "
                        + "\(recordURL.path)."
                )
            }

            let destinationData = try readData(at: destinationURL)
            let destinationMetadata = try metadataSnapshot(at: destinationURL)
            let destinationIsStaged = sha256(destinationData) == record.stagedDataSHA256
                && destinationMetadata == record.stagedMetadata
            guard fileManager.fileExists(atPath: temporaryURL.path) else {
                if destinationIsStaged
                    || (sha256(destinationData) == record.expectedDataSHA256
                        && destinationMetadata == record.expectedMetadata) {
                    try fileManager.removeItem(at: recordURL)
                    try syncDirectory(directory)
                    continue
                }
                throw interruptedExchangeError(recordURL: recordURL, temporaryURL: temporaryURL)
            }

            let temporaryData = try readData(at: temporaryURL)
            let temporaryMetadata = try metadataSnapshot(at: temporaryURL)
            let temporaryIsStaged = sha256(temporaryData) == record.stagedDataSHA256
                && temporaryMetadata == record.stagedMetadata
            if temporaryIsStaged && !destinationIsStaged {
                try fileManager.removeItem(at: temporaryURL)
                try fileManager.removeItem(at: recordURL)
                try syncDirectory(directory)
                continue
            }
            if destinationIsStaged && !temporaryIsStaged {
                guard exchange(temporaryURL, destinationURL) == 0 else {
                    throw posixError("restore interrupted exchange at \(destinationURL.path)")
                }
                try syncDirectory(directory)
                try fileManager.removeItem(at: temporaryURL)
                try fileManager.removeItem(at: recordURL)
                try syncDirectory(directory)
                continue
            }
            throw interruptedExchangeError(recordURL: recordURL, temporaryURL: temporaryURL)
        }
    }

    private func interruptedExchangeError(recordURL: URL, temporaryURL: URL) -> JobWrapperError {
        JobWrapperError(
            message: "Ticker could not safely reconcile an interrupted plist exchange. "
                + "Preserve \(recordURL.path) and \(temporaryURL.path), then compare them with the live plist."
        )
    }

    private func sourceChangedError(at plistURL: URL) -> JobWrapperError {
        JobWrapperError(
            message: "Launchd plist at \(plistURL.path) changed while Ticker was preparing "
                + "to rewrite it. Ticker did not modify the plist. Review the current file and retry."
        )
    }

    private func ensureMetadataUnchanged(
        _ expectedMetadata: FileMetadataSnapshot,
        at url: URL
    ) throws {
        guard try metadataSnapshot(at: url) == expectedMetadata else {
            throw sourceChangedError(at: url)
        }
    }

    private func metadataSnapshot(at url: URL) throws -> FileMetadataSnapshot {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else {
            throw posixError("inspect metadata at \(url.path)")
        }
        return FileMetadataSnapshot(
            ownerID: info.st_uid,
            groupID: info.st_gid,
            mode: info.st_mode,
            flags: info.st_flags,
            aclText: try aclText(at: url),
            extendedAttributes: try extendedAttributes(at: url)
        )
    }

    private func aclText(at url: URL) throws -> String? {
        errno = 0
        guard let acl = url.path.withCString({ acl_get_file($0, ACL_TYPE_EXTENDED) }) else {
            if errno == ENOENT || errno == ENOTSUP {
                return nil
            }
            throw posixError("read ACL at \(url.path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = ssize_t(0)
        guard let text = acl_to_text(acl, &length) else {
            throw posixError("serialize ACL at \(url.path)")
        }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private func extendedAttributes(at url: URL) throws -> [String: Data] {
        let size = url.path.withCString {
            Darwin.listxattr($0, nil, 0, XATTR_NOFOLLOW)
        }
        guard size >= 0 else {
            throw posixError("list extended attributes at \(url.path)")
        }
        guard size > 0 else {
            return [:]
        }
        var names = [CChar](repeating: 0, count: size)
        let readSize = names.withUnsafeMutableBufferPointer { buffer in
            url.path.withCString {
                Darwin.listxattr($0, buffer.baseAddress, buffer.count, XATTR_NOFOLLOW)
            }
        }
        guard readSize == size else {
            throw posixError("read extended-attribute names at \(url.path)")
        }

        var result: [String: Data] = [:]
        var offset = 0
        while offset < readSize {
            let name = names.withUnsafeBufferPointer { buffer -> String in
                String(cString: buffer.baseAddress!.advanced(by: offset))
            }
            offset += name.utf8.count + 1
            let valueSize = url.path.withCString { path in
                name.withCString { attribute in
                    Darwin.getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
                }
            }
            guard valueSize >= 0 else {
                throw posixError("read extended attribute \(name) at \(url.path)")
            }
            var value = Data(count: valueSize)
            let bytesRead = value.withUnsafeMutableBytes { buffer in
                url.path.withCString { path in
                    name.withCString { attribute in
                        Darwin.getxattr(
                            path,
                            attribute,
                            buffer.baseAddress,
                            buffer.count,
                            0,
                            XATTR_NOFOLLOW
                        )
                    }
                }
            }
            guard bytesRead == valueSize else {
                throw posixError("read extended attribute \(name) at \(url.path)")
            }
            result[name] = value
        }
        return result
    }

    private func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw JobWrapperError(message: "Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    private func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-")
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
