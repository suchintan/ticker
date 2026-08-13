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
    case wrappedMissingBackup
    case wrappedBackupContentMismatch
    case wrappedBackupUnverified
    case wrappedForeignLabel(embeddedJobID: String)
    case ambiguousTickerInvocation
    case staleManagedRow

    public var description: String {
        switch self {
        case .unwrapped:
            return "unwrapped"
        case .wrappedConsistent:
            return "wrapped-consistent"
        case .wrappedMissingBackup:
            return "wrapped-missing-backup"
        case .wrappedBackupContentMismatch:
            return "wrapped-backup-content-mismatch"
        case .wrappedBackupUnverified:
            return "wrapped-backup-unverified"
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
    let backupByteCount: Int?
    let backupSHA256: String?
}

private enum BackupResolution {
    case verified(URL)
    case missing
    case contentMismatch([URL])
    case unverified([URL])
}

private enum BackupValidation {
    case verified
    case contentMismatch
    case unverified
}

private struct OriginalExecution: Equatable {
    let command: [String]
    let argv0: String?
}

public final class JobWrapper {
    private let store: RunStore
    private let backupDirectory: URL
    private let fileManager: FileManager
    private let beforeSourceRewrite: (() throws -> Void)?

    public init(store: RunStore) {
        self.store = store
        fileManager = .default
        backupDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ticker", isDirectory: true)
            .appendingPathComponent("backups", isDirectory: true)
        beforeSourceRewrite = nil
    }

    public init(store: RunStore, backupDirectory: URL, fileManager: FileManager = .default) {
        self.store = store
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        beforeSourceRewrite = nil
    }

    init(
        store: RunStore,
        backupDirectory: URL,
        fileManager: FileManager = .default,
        beforeSourceRewrite: @escaping () throws -> Void
    ) {
        self.store = store
        self.backupDirectory = backupDirectory
        self.fileManager = fileManager
        self.beforeSourceRewrite = beforeSourceRewrite
    }

    public func wrap(job: Job, tickerPath: String) throws -> ReloadCommands {
        let plistURL = try configurationURL(for: job)
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
            try migrateWrapperIfNeeded(
                dictionary: &dictionary,
                format: format,
                plistURL: plistURL,
                job: job,
                tickerPath: tickerPath,
                expectedSourceData: originalData
            )
            return commands
        case .wrappedBackupContentMismatch:
            throw JobWrapperError(
                message: "Ticker backup content for \(job.id) does not match its authenticated metadata; refusing to rewrite the plist"
            )
        case .wrappedBackupUnverified:
            throw JobWrapperError(
                message: "Ticker backup for \(job.id) has no valid content digest; explicit recovery is required"
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
            }

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
        try beforeSourceRewrite?()
        try ensureSourceUnchanged(originalData, at: plistURL)
        try store.markManaged(jobID: job.id, backupPath: backupURL.path)

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
            try ensureSourceUnchanged(originalData, at: plistURL)
            try writeRewrittenData(rewrittenData, to: plistURL)
        } catch {
            try? store.unmarkManaged(jobID: job.id)
            throw error
        }

        return commands
    }

    public func unwrap(job: Job) throws -> ReloadCommands {
        let plistURL = try configurationURL(for: job)
        let commands = reloadCommands(for: plistURL)
        let state = try recoveryState(job: job)
        switch state {
        case .wrappedConsistent:
            break
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
        case .wrappedBackupUnverified:
            throw JobWrapperError(
                message: "Ticker backup for \(job.id) has no valid content digest; explicit recovery is required"
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

        guard case .verified(let backupURL) = try backupResolution(for: job, plistURL: plistURL) else {
            throw JobWrapperError(message: "No verified Ticker backup exists for \(job.id)")
        }
        let backupData = try authenticatedBackupData(
            at: backupURL,
            job: job,
            plistURL: plistURL
        )
        let liveData = try readData(at: plistURL)
        var liveFormat = PropertyListSerialization.PropertyListFormat.xml
        var liveDictionary = try propertyListDictionary(
            from: liveData,
            format: &liveFormat,
            plistURL: plistURL
        )
        let backupDictionary = try propertyListDictionary(
            from: backupData,
            format: nil,
            plistURL: backupURL
        )
        guard wrapperMatchesBackup(
            liveDictionary: liveDictionary,
            backupDictionary: backupDictionary,
            job: job
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
        try ensureSourceUnchanged(liveData, at: plistURL)
        try writeRewrittenData(
            try serializedData(liveDictionary, format: liveFormat, plistURL: plistURL),
            to: plistURL
        )

        try store.unmarkManaged(jobID: job.id)
        return commands
    }

    public func recoveryState(job: Job) throws -> JobRecoveryState {
        let plistURL = try configurationURL(for: job)
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
        let managedRowExists = !managedIDs.isDisjoint(with: acceptedBackupJobIDs(for: job))
        let arguments = dictionary["ProgramArguments"] as? [String]
        let acceptedLabels = acceptedWrapperLabels(for: job)
        if let arguments, let decoded = LaunchdWrapper.decode(arguments) {
            guard acceptedLabels.contains(decoded.label) else {
                return .wrappedForeignLabel(embeddedJobID: decoded.label)
            }
            guard managedRowExists else {
                return .wrappedMissingBackup
            }
            switch try backupResolution(for: job, plistURL: plistURL) {
            case .verified(let backupURL):
                let backupDictionary = try authenticatedBackupDictionary(
                    at: backupURL,
                    job: job,
                    plistURL: plistURL
                )
                return wrapperMatchesBackup(
                    liveDictionary: dictionary,
                    backupDictionary: backupDictionary,
                    job: job
                ) ? .wrappedConsistent : .ambiguousTickerInvocation
            case .missing:
                return .wrappedMissingBackup
            case .contentMismatch:
                return .wrappedBackupContentMismatch
            case .unverified:
                return .wrappedBackupUnverified
            }
        }

        if let arguments, let legacy = LaunchdWrapper.decodeLegacy(arguments) {
            guard acceptedLabels.contains(legacy.label),
                  managedRowExists,
                  case .verified(let backupURL) = try backupResolution(for: job, plistURL: plistURL) else {
                return .ambiguousTickerInvocation
            }
            let backupDictionary = try authenticatedBackupDictionary(
                at: backupURL,
                job: job,
                plistURL: plistURL
            )
            return wrapperMatchesBackup(
                liveDictionary: dictionary,
                backupDictionary: backupDictionary,
                job: job
            ) ? .wrappedConsistent : .ambiguousTickerInvocation
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
        case .unverified:
            return .wrappedBackupUnverified
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

    private func backupResolution(for job: Job, plistURL: URL) throws -> BackupResolution {
        var candidates: [URL] = []
        var seenPaths = Set<String>()
        func appendCandidate(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seenPaths.insert(standardized.path).inserted {
                candidates.append(standardized)
            }
        }

        if let sqliteStore = store as? SQLiteRunStore,
           let path = try managedBackupPath(for: job, in: sqliteStore) {
            let storedURL = URL(fileURLWithPath: path).standardizedFileURL
            if fileManager.fileExists(atPath: storedURL.path) {
                switch backupValidation(backupURL: storedURL, job: job, plistURL: plistURL) {
                case .verified:
                    return .verified(storedURL)
                case .contentMismatch:
                    return .contentMismatch([storedURL])
                case .unverified:
                    return .unverified([storedURL])
                }
            }
        }

        if fileManager.fileExists(atPath: backupDirectory.path) {
            do {
                let currentPrefix = backupStem(for: job) + ".plist."
                let legacyPrefix = sanitizedLabel(job.label) + ".plist."
                for candidate in try fileManager.contentsOfDirectory(
                    at: backupDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) {
                    let name = candidate.lastPathComponent
                    guard !name.hasSuffix(".metadata.json"),
                          name.hasPrefix(currentPrefix) || name.hasPrefix(legacyPrefix) else {
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
        var unverified: [URL] = []
        for candidate in candidates {
            switch backupValidation(backupURL: candidate, job: job, plistURL: plistURL) {
            case .verified:
                verified.append(candidate)
            case .contentMismatch:
                mismatched.append(candidate)
            case .unverified:
                unverified.append(candidate)
            }
        }
        if let newest = newestBackup(in: verified) {
            return .verified(newest)
        }
        if !mismatched.isEmpty {
            return .contentMismatch(mismatched)
        }
        if !unverified.isEmpty {
            return .unverified(unverified)
        }
        return .missing
    }

    private func managedBackupPath(for job: Job, in store: SQLiteRunStore) throws -> String? {
        if let current = try store.managedBackupPath(jobID: job.id) {
            return current
        }
        if let legacy = legacyJobID(for: job) {
            return try store.managedBackupPath(jobID: legacy)
        }
        return nil
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
        var epoch = Int64(Date().timeIntervalSince1970 * 1_000)
        while true {
            let candidate = backupDirectory.appendingPathComponent(
                "\(backupStem(for: job)).plist.\(epoch)",
                isDirectory: false
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            epoch += 1
        }
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

    private func backupValidation(backupURL: URL, job: Job, plistURL: URL) -> BackupValidation {
        guard let metadataData = try? Data(contentsOf: metadataURL(for: backupURL)),
              let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: metadataData),
              let backupData = try? Data(contentsOf: backupURL) else {
            return .unverified
        }
        return backupValidation(
            metadata: metadata,
            backupData: backupData,
            job: job,
            plistURL: plistURL
        )
    }

    private func backupValidation(
        metadata: BackupMetadata,
        backupData: Data,
        job: Job,
        plistURL: URL
    ) -> BackupValidation {
        guard metadata.version == 2,
              acceptedBackupJobIDs(for: job).contains(metadata.jobID),
              metadata.sourcePlistPath == canonicalPath(plistURL),
              let expectedByteCount = metadata.backupByteCount,
              let expectedDigest = metadata.backupSHA256 else {
            return .unverified
        }
        guard backupData.count == expectedByteCount,
              sha256(backupData) == expectedDigest else {
            return .contentMismatch
        }
        return .verified
    }

    private func authenticatedBackupData(at backupURL: URL, job: Job, plistURL: URL) throws -> Data {
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
        switch backupValidation(
            metadata: metadata,
            backupData: backupData,
            job: job,
            plistURL: plistURL
        ) {
        case .verified:
            return backupData
        case .contentMismatch:
            throw JobWrapperError(
                message: "Backup content at \(backupURL.path) changed after it was recorded; refusing to restore it"
            )
        case .unverified:
            throw JobWrapperError(
                message: "Backup metadata at \(metadataURL(for: backupURL).path) has no valid content digest"
            )
        }
    }

    private func authenticatedBackupDictionary(
        at backupURL: URL,
        job: Job,
        plistURL: URL
    ) throws -> [String: Any] {
        try propertyListDictionary(
            from: authenticatedBackupData(at: backupURL, job: job, plistURL: plistURL),
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
        job: Job
    ) -> Bool {
        guard !liveDictionary.keys.contains("Program"),
              let arguments = liveDictionary["ProgramArguments"] as? [String],
              let decoded = LaunchdWrapper.decode(arguments) ?? LaunchdWrapper.decodeLegacy(arguments),
              acceptedWrapperLabels(for: job).contains(decoded.label),
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
              let decoded = LaunchdWrapper.decode(arguments) ?? LaunchdWrapper.decodeLegacy(arguments) else {
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
        try beforeSourceRewrite?()
        try ensureSourceUnchanged(expectedSourceData, at: plistURL)
        try writeRewrittenData(
            try serializedData(dictionary, format: format, plistURL: plistURL),
            to: plistURL
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
        return acceptedBackupJobIDs(for: job)
    }

    private func acceptedBackupJobIDs(for job: Job) -> Set<String> {
        var result: Set<String> = [job.id]
        if let legacy = legacyJobID(for: job) {
            result.insert(legacy)
        }
        return result
    }

    private func legacyJobID(for job: Job) -> String? {
        guard job.source == .launchd || job.source == .claudeRoutine,
              let separator = job.id.lastIndex(of: "#") else {
            return nil
        }
        let suffix = job.id[job.id.index(after: separator)...]
        guard suffix.count == 12,
              suffix.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return String(job.id[..<separator])
    }

    private func canonicalPath(_ url: URL) -> String {
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func sha256(_ data: Data) -> String {
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func persistBackup(_ data: Data, to backupURL: URL) throws {
        try atomicWrite(data, to: backupURL, preservingMetadataFrom: nil)
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

    private func writeRewrittenData(_ data: Data, to plistURL: URL) throws {
        try atomicWrite(data, to: plistURL, preservingMetadataFrom: plistURL)
    }

    private func atomicWrite(
        _ data: Data,
        to destinationURL: URL,
        preservingMetadataFrom metadataSourceURL: URL?
    ) throws {
        let directory = destinationURL.deletingLastPathComponent()
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
        defer {
            if let fileDescriptor {
                _ = Darwin.close(fileDescriptor)
            }
            if temporaryFileExists {
                try? fileManager.removeItem(at: temporaryURL)
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

        let renameResult = temporaryURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else {
            throw posixError("rename temporary file into place at \(destinationURL.path)")
        }
        temporaryFileExists = false
        try syncDirectory(directory)
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
