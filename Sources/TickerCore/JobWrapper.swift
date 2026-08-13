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
    case wrappedForeignLabel(embeddedJobID: String)
    case staleManagedRow

    public var description: String {
        switch self {
        case .unwrapped:
            return "unwrapped"
        case .wrappedConsistent:
            return "wrapped-consistent"
        case .wrappedMissingBackup:
            return "wrapped-missing-backup"
        case .wrappedForeignLabel(let embeddedJobID):
            return "wrapped-foreign-label (\(embeddedJobID))"
        case .staleManagedRow:
            return "stale-row"
        }
    }
}

private struct BackupMetadata: Codable {
    let version: Int
    let jobID: String
    let sourcePlistPath: String
}

private enum BackupResolution {
    case verified(URL)
    case missing
    case unverifiable([URL])
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
            try migrateWrapperPathIfNeeded(
                dictionary: &dictionary,
                format: format,
                plistURL: plistURL,
                tickerPath: tickerPath
            )
            return commands
        case .wrappedForeignLabel(let embeddedJobID):
            throw JobWrapperError(
                message: "Launchd job \(job.id) contains a Ticker wrapper for \(embeddedJobID); refusing to replace it"
            )
        case .wrappedMissingBackup:
            guard let decodedWrapper, decodedWrapper.label == job.id else {
                throw JobWrapperError(message: "Could not decode the existing Ticker wrapper for \(job.id)")
            }

            if case .verified(let backupURL) = try backupResolution(for: job, plistURL: plistURL) {
                try store.markManaged(jobID: job.id, backupPath: backupURL.path)
            } else if let migratedURL = try migrateLegacyBackupIfSafe(
                job: job,
                plistURL: plistURL,
                wrappedDictionary: dictionary,
                decodedWrapper: decodedWrapper
            ) {
                try store.markManaged(jobID: job.id, backupPath: migratedURL.path)
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

            try migrateWrapperPathIfNeeded(
                dictionary: &dictionary,
                format: format,
                plistURL: plistURL,
                tickerPath: tickerPath
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
        try store.markManaged(jobID: job.id, backupPath: backupURL.path)

        dictionary.removeValue(forKey: "Program")
        var wrapperArguments = [
            tickerPath,
            "run",
            "--label",
            job.id,
        ]
        if let argv0 = originalExecution.argv0 {
            wrapperArguments += ["--argv0", argv0]
        }
        wrapperArguments += ["--"] + originalExecution.command
        dictionary["ProgramArguments"] = wrapperArguments

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
        let backupData = try readData(at: backupURL)
        do {
            try backupData.write(to: plistURL, options: .atomic)
        } catch {
            throw JobWrapperError(
                message: "Could not restore \(plistURL.path) from \(backupURL.path): \(error.localizedDescription)"
            )
        }

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

        let managedRowExists = try store.managedJobIDs().contains(job.id)
        guard let arguments = dictionary["ProgramArguments"] as? [String],
              let decoded = LaunchdWrapper.decode(arguments) else {
            return managedRowExists ? .staleManagedRow : .unwrapped
        }
        guard decoded.label == job.id else {
            return .wrappedForeignLabel(embeddedJobID: decoded.label)
        }
        guard managedRowExists else {
            return .wrappedMissingBackup
        }
        guard case .verified = try backupResolution(for: job, plistURL: plistURL) else {
            return .wrappedMissingBackup
        }
        return .wrappedConsistent
    }

    public func isWrapped(job: Job) -> Bool {
        guard let configPath = job.configPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ),
              let dictionary = propertyList as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String],
              let decoded = LaunchdWrapper.decode(arguments)
        else {
            return false
        }
        return decoded.label == job.id
    }

    private func configurationURL(for job: Job) throws -> URL {
        guard job.source == .launchd else {
            throw JobWrapperError(message: "Only launchd jobs can be wrapped; \(job.id) is \(job.source.rawValue)")
        }
        guard let configPath = job.configPath, !configPath.isEmpty else {
            throw JobWrapperError(message: "Launchd job \(job.id) has no plist path")
        }
        return URL(fileURLWithPath: configPath).standardizedFileURL
    }

    private func reloadCommands(for plistURL: URL) -> ReloadCommands {
        let path = shellQuoted(plistURL.path)
        return ReloadCommands(
            unload: "launchctl unload \(path)",
            load: "launchctl load \(path)"
        )
    }

    private func backupResolution(for job: Job, plistURL: URL) throws -> BackupResolution {
        var unverifiable: [URL] = []
        if let sqliteStore = store as? SQLiteRunStore,
           let path = try sqliteStore.managedBackupPath(jobID: job.id) {
            let storedURL = URL(fileURLWithPath: path).standardizedFileURL
            if fileManager.fileExists(atPath: storedURL.path) {
                if metadataMatches(backupURL: storedURL, job: job, plistURL: plistURL) {
                    return .verified(storedURL)
                }
                unverifiable.append(storedURL)
            }
        }

        if !fileManager.fileExists(atPath: backupDirectory.path) {
            return unverifiable.isEmpty ? .missing : .unverifiable(unverifiable)
        }
        let candidates: [URL]
        do {
            let currentPrefix = backupStem(for: job) + ".plist."
            let legacyPrefix = sanitizedLabel(job.label) + ".plist."
            candidates = try fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { candidate in
                let name = candidate.lastPathComponent
                guard !name.hasSuffix(".metadata.json") else {
                    return false
                }
                return name.hasPrefix(currentPrefix) || name.hasPrefix(legacyPrefix)
            }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return unverifiable.isEmpty ? .missing : .unverifiable(unverifiable)
        } catch {
            throw JobWrapperError(
                message: "Could not inspect backup directory at \(backupDirectory.path): \(error.localizedDescription)"
            )
        }

        let verified = candidates.filter {
            metadataMatches(backupURL: $0, job: job, plistURL: plistURL)
        }
        if let newest = newestBackup(in: verified) {
            return .verified(newest)
        }
        unverifiable.append(contentsOf: candidates)
        return unverifiable.isEmpty ? .missing : .unverifiable(unverifiable)
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

    private func metadataMatches(backupURL: URL, job: Job, plistURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: metadataURL(for: backupURL)),
              let metadata = try? JSONDecoder().decode(BackupMetadata.self, from: data) else {
            return false
        }
        return metadata.version == 1
            && metadata.jobID == job.id
            && metadata.sourcePlistPath == plistURL.standardizedFileURL.path
    }

    private func persistBackupWithMetadata(
        _ data: Data,
        to backupURL: URL,
        job: Job,
        plistURL: URL
    ) throws {
        try persistBackup(data, to: backupURL)
        let metadata = BackupMetadata(
            version: 1,
            jobID: job.id,
            sourcePlistPath: plistURL.standardizedFileURL.path
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

    private func migrateLegacyBackupIfSafe(
        job: Job,
        plistURL: URL,
        wrappedDictionary: [String: Any],
        decodedWrapper: (label: String, original: [String], argv0: String?)
    ) throws -> URL? {
        guard let sqliteStore = store as? SQLiteRunStore,
              let path = try sqliteStore.managedBackupPath(jobID: job.id) else {
            return nil
        }
        let backupURL = URL(fileURLWithPath: path).standardizedFileURL
        guard fileManager.fileExists(atPath: backupURL.path),
              !fileManager.fileExists(atPath: metadataURL(for: backupURL).path),
              legacyBackup(
                  backupURL,
                  matches: wrappedDictionary,
                  decodedWrapper: decodedWrapper,
                  jobID: job.id
              ) else {
            return nil
        }

        let metadata = BackupMetadata(
            version: 1,
            jobID: job.id,
            sourcePlistPath: plistURL.standardizedFileURL.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try persistBackup(try encoder.encode(metadata), to: metadataURL(for: backupURL))
        return backupURL
    }

    private func legacyBackup(
        _ backupURL: URL,
        matches wrappedDictionary: [String: Any],
        decodedWrapper: (label: String, original: [String], argv0: String?),
        jobID: String
    ) -> Bool {
        guard decodedWrapper.label == jobID,
              let data = try? Data(contentsOf: backupURL),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let backupDictionary = value as? [String: Any],
              let backupExecution = try? execution(from: backupDictionary, fallback: [], jobID: jobID),
              backupExecution == OriginalExecution(
                  command: decodedWrapper.original,
                  argv0: decodedWrapper.argv0
              ) else {
            return false
        }

        var backupRemainder = backupDictionary
        backupRemainder.removeValue(forKey: "Program")
        backupRemainder.removeValue(forKey: "ProgramArguments")
        var wrappedRemainder = wrappedDictionary
        wrappedRemainder.removeValue(forKey: "Program")
        wrappedRemainder.removeValue(forKey: "ProgramArguments")
        return NSDictionary(dictionary: backupRemainder).isEqual(to: wrappedRemainder)
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

    private func migrateWrapperPathIfNeeded(
        dictionary: inout [String: Any],
        format: PropertyListSerialization.PropertyListFormat,
        plistURL: URL,
        tickerPath: String
    ) throws {
        guard var arguments = dictionary["ProgramArguments"] as? [String],
              LaunchdWrapper.decode(arguments) != nil,
              arguments[0] != tickerPath else {
            return
        }
        arguments[0] = tickerPath
        dictionary["ProgramArguments"] = arguments
        try beforeSourceRewrite?()
        try writeRewrittenData(
            try serializedData(dictionary, format: format, plistURL: plistURL),
            to: plistURL
        )
    }

    private func persistBackup(_ data: Data, to backupURL: URL) throws {
        let temporaryURL = backupDirectory.appendingPathComponent(
            ".\(backupURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw posixError("create backup temporary file at \(temporaryURL.path)")
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
                    throw posixError("write backup temporary file at \(temporaryURL.path)")
                }
                offset += result
            }
        }
        try fullySync(descriptor, description: "backup temporary file at \(temporaryURL.path)")
        guard Darwin.close(descriptor) == 0 else {
            throw posixError("close backup temporary file at \(temporaryURL.path)")
        }
        fileDescriptor = nil

        let renameResult = temporaryURL.path.withCString { source in
            backupURL.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else {
            throw posixError("rename backup into place at \(backupURL.path)")
        }
        temporaryFileExists = false
        try syncDirectory(backupDirectory)
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            throw posixError("open backup directory at \(directory.path)")
        }
        defer { _ = Darwin.close(descriptor) }
        try fullySync(descriptor, description: "backup directory at \(directory.path)")
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
        do {
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw JobWrapperError(
                message: "Could not rewrite launchd plist at \(plistURL.path): \(error.localizedDescription)"
            )
        }
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
