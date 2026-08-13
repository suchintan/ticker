import Darwin
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

        if let arguments = dictionary["ProgramArguments"] as? [String],
           LaunchdWrapper.decode(arguments) != nil {
            guard arguments[0] != tickerPath else {
                return commands
            }

            var migratedArguments = arguments
            migratedArguments[0] = tickerPath
            dictionary["ProgramArguments"] = migratedArguments
            let rewrittenData = try serializedData(
                dictionary,
                format: format,
                plistURL: plistURL
            )
            try writeRewrittenData(rewrittenData, to: plistURL)
            return commands
        }

        let originalArguments: [String]
        if let arguments = dictionary["ProgramArguments"] as? [String], !arguments.isEmpty {
            originalArguments = arguments
        } else if let program = dictionary["Program"] as? String, !program.isEmpty {
            originalArguments = [program]
        } else if !job.command.isEmpty {
            originalArguments = job.command
        } else {
            throw JobWrapperError(message: "Launchd job \(job.id) has no command to wrap")
        }

        do {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        } catch {
            throw JobWrapperError(
                message: "Could not create backup directory at \(backupDirectory.path): \(error.localizedDescription)"
            )
        }

        let backupURL = uniqueBackupURL(label: job.label)
        try persistBackup(originalData, to: backupURL)
        try beforeSourceRewrite?()

        try store.markManaged(jobID: job.id, backupPath: backupURL.path)

        dictionary.removeValue(forKey: "Program")
        dictionary["ProgramArguments"] = [
            tickerPath,
            "run",
            "--label",
            job.id,
            "--",
        ] + originalArguments

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
        guard let backupURL = try backupURL(for: job) else {
            throw JobWrapperError(message: "No Ticker backup exists for \(job.id)")
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

    public func isWrapped(job: Job) -> Bool {
        guard let configPath = job.configPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            return false
        }

        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ),
        let dictionary = propertyList as? [String: Any],
        let arguments = dictionary["ProgramArguments"] as? [String],
        arguments.count >= 5 else {
            return false
        }

        return arguments[1] == "run"
            && arguments[2] == "--label"
            && arguments[3] == job.id
            && arguments[4] == "--"
    }

    private func configurationURL(for job: Job) throws -> URL {
        guard job.source == .launchd else {
            throw JobWrapperError(message: "Only launchd jobs can be wrapped; \(job.id) is \(job.source.rawValue)")
        }
        guard let configPath = job.configPath, !configPath.isEmpty else {
            throw JobWrapperError(message: "Launchd job \(job.id) has no plist path")
        }
        return URL(fileURLWithPath: configPath)
    }

    private func reloadCommands(for plistURL: URL) -> ReloadCommands {
        let path = shellQuoted(plistURL.path)
        return ReloadCommands(
            unload: "launchctl unload \(path)",
            load: "launchctl load \(path)"
        )
    }

    private func backupURL(for job: Job) throws -> URL? {
        if let sqliteStore = store as? SQLiteRunStore,
           let path = try sqliteStore.managedBackupPath(jobID: job.id) {
            return URL(fileURLWithPath: path)
        }

        let prefix = sanitizedLabel(job.label) + ".plist."
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasPrefix(prefix) }
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw JobWrapperError(
                message: "Could not inspect backup directory at \(backupDirectory.path): \(error.localizedDescription)"
            )
        }

        return candidates.max { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date.distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? Date.distantPast
            return leftDate < rightDate
        }
    }

    private func uniqueBackupURL(label: String) -> URL {
        var epoch = Int64(Date().timeIntervalSince1970 * 1_000)
        while true {
            let candidate = backupDirectory.appendingPathComponent(
                "\(sanitizedLabel(label)).plist.\(epoch)",
                isDirectory: false
            )
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            epoch += 1
        }
    }

    private func sanitizedLabel(_ label: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        return label.components(separatedBy: forbidden).joined(separator: "_")
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
