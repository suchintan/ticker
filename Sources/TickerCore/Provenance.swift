import Darwin
import Foundation

public enum JobProvenance: Hashable {
    case yours
    case app(String)
    case packageManager(String)
    case system
    case unknown(String)

    public var kind: String {
        switch self {
        case .yours:
            return "yours"
        case .app:
            return "app"
        case .packageManager:
            return "packageManager"
        case .system:
            return "system"
        case .unknown:
            return "unknown"
        }
    }

    public var displayName: String {
        switch self {
        case .yours:
            return "Yours"
        case .app(let name):
            return name
        case .packageManager(let name):
            return name
        case .system:
            return "macOS"
        case .unknown:
            return "Unknown owner"
        }
    }

    public var isYours: Bool {
        self == .yours
    }
}

extension JobProvenance: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "yours":
            self = .yours
        case "app":
            self = .app(try container.decode(String.self, forKey: .name))
        case "packageManager":
            self = .packageManager(try container.decode(String.self, forKey: .name))
        case "system":
            self = .system
        case "unknown":
            self = .unknown(try container.decode(String.self, forKey: .reason))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown job provenance kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .app(let name), .packageManager(let name):
            try container.encode(name, forKey: .name)
        case .unknown(let reason):
            try container.encode(reason, forKey: .reason)
        case .yours, .system:
            break
        }
    }
}

public enum JobAttention: Hashable {
    case missingPayload(String)

    public var kind: String {
        switch self {
        case .missingPayload:
            return "missingPayload"
        }
    }

    public var path: String {
        switch self {
        case .missingPayload(let path):
            return path
        }
    }

    public var summary: String {
        switch self {
        case .missingPayload:
            return "Missing payload"
        }
    }
}

extension JobAttention: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "missingPayload":
            self = .missingPayload(try container.decode(String.self, forKey: .path))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown job attention kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(path, forKey: .path)
    }
}

internal struct JobClassification: Equatable {
    internal let provenance: JobProvenance
    internal let attention: JobAttention?
}

internal final class JobProvenanceClassifier {
    private struct FileIdentity: Hashable {
        let path: String
        let device: UInt64?
        let inode: UInt64?
        let modifiedSeconds: Int64?
        let modifiedNanoseconds: Int64?
        let size: Int64?
    }

    private struct CacheKey: Hashable {
        let plist: FileIdentity
        let program: FileIdentity
        let command: [String]
    }

    private struct CacheEntry {
        let key: CacheKey
        let classification: JobClassification
    }

    private static let packageManagerPrefixes = [
        "/opt/homebrew/",
        "/usr/local/Cellar/",
        "/opt/local/",
        "/usr/local/opt/",
    ]

    private static let vendorPrefixes = [
        "/Applications/",
        "/Library/Application Support/",
        "/Library/PrivilegedHelperTools/",
        "/Library/Scripts/",
        "/var/lib/",
        "/opt/",
    ]

    private static let systemPrefixes = [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/",
    ]

    // macOS can redact Authority while still returning the signature's TeamIdentifier.
    // These cryptographically bound team IDs preserve the validated authority display
    // names instead of falling through to a path guess or Unknown.
    private static let developerIDNamesByTeamIdentifier = [
        "94KV3E626L": "AMZN Mobile LLC",
        "Y93TK974AT": "Bjango Pty Ltd",
        "2K8T33D25Z": "Cyolo",
        "EQHXZ8M8AV": "Google LLC",
        "LZ26LAU7JM": "Groupnotes Inc",
        "38ZC4T8AWY": "Island Technology, Inc",
        "QXD7GW8FHY": "Louis Pontoise",
        "UBF8T346G9": "Microsoft Corporation",
        "S3965T6BV3": "Oneleet Inc.",
        "GYZJYS7XUG": "Windscribe Limited",
        "BJ4HAAB9B3": "Zoom Video Communications, Inc.",
    ]

    private let homeDirectory: String
    private let codesignURL: URL
    private let signatureRunner: AdapterCommandRunner
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]

    internal init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codesignURL: URL = URL(fileURLWithPath: "/usr/bin/codesign"),
        fileManager: FileManager = .default,
        signatureRunner: @escaping AdapterCommandRunner
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL.path
        self.codesignURL = codesignURL
        self.fileManager = fileManager
        self.signatureRunner = signatureRunner
    }

    internal func classify(
        source: JobSource,
        command: [String],
        configPath: String?
    ) -> JobClassification {
        guard source == .launchd else {
            return JobClassification(provenance: .yours, attention: nil)
        }

        let program = command.first ?? ""
        let cacheSlot = configPath ?? "unidentified:\(command.joined(separator: "\u{1f}"))"
        let key = CacheKey(
            plist: fileIdentity(configPath ?? cacheSlot),
            program: fileIdentity(program),
            command: command
        )

        lock.lock()
        if let entry = cache[cacheSlot], entry.key == key {
            lock.unlock()
            return entry.classification
        }
        lock.unlock()

        let payload = command.dropFirst().first { $0.hasPrefix("/") }
        let launchdClassification = classifyLaunchd(program: program, payload: payload)
        let attention = launchdClassification.payload.flatMap { path -> JobAttention? in
            let standardized = standardizedPath(path)
            return fileManager.fileExists(atPath: standardized)
                ? nil
                : .missingPayload(standardized)
        }
        let result = JobClassification(
            provenance: launchdClassification.provenance,
            attention: attention
        )

        lock.lock()
        cache[cacheSlot] = CacheEntry(key: key, classification: result)
        lock.unlock()
        return result
    }

    private func classifyLaunchd(
        program: String,
        payload: String?
    ) -> (provenance: JobProvenance, payload: String?) {
        let programPath = standardizedPath(program)
        if hasPrefix(programPath, in: Self.packageManagerPrefixes) {
            return (.packageManager("Homebrew"), nil)
        }

        if programPath.hasPrefix("/"),
           let authority = developerIDAuthority(for: programPath) {
            return (.app(normalizedAppName(authority)), nil)
        }

        if let name = vendorName(for: programPath) {
            return (.app(name), nil)
        }

        if let payload {
            let payloadPath = standardizedPath(payload)
            if isInsideHome(payloadPath) {
                return (.yours, payload)
            }
            if hasPrefix(payloadPath, in: Self.packageManagerPrefixes) {
                return (.packageManager("Homebrew"), payload)
            }
            if let name = vendorName(for: payloadPath) {
                return (.app(name), payload)
            }
        }

        if hasPrefix(programPath, in: Self.systemPrefixes) {
            return (.system, payload)
        }
        if program.isEmpty {
            return (.unknown("launchd job has no program"), payload)
        }
        return (.unknown("could not attribute \(program)"), payload)
    }

    private func developerIDAuthority(for program: String) -> String? {
        guard let result = try? signatureRunner(
            codesignURL,
            ["-dv", "--verbose=4", program]
        ), result.status == 0 else {
            return nil
        }
        let prefix = "Authority=Developer ID Application:"
        let output = result.stdout + "\n" + result.stderr
        var teamIdentifier: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("TeamIdentifier=") {
                teamIdentifier = String(line.dropFirst("TeamIdentifier=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard line.hasPrefix(prefix) else {
                continue
            }
            var authority = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if authority.hasSuffix(")"),
               let opening = authority.lastIndex(of: "("),
               opening > authority.startIndex {
                let before = authority.index(before: opening)
                if authority[before].isWhitespace {
                    authority = String(authority[..<before])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return authority.isEmpty ? nil : authority
        }
        return teamIdentifier.flatMap { Self.developerIDNamesByTeamIdentifier[$0] }
    }

    private func vendorName(for path: String) -> String? {
        guard !hasPrefix(path, in: Self.packageManagerPrefixes) else {
            return nil
        }
        for prefix in Self.vendorPrefixes where path.hasPrefix(prefix) {
            let remainder = path.dropFirst(prefix.count)
            guard let first = remainder.split(separator: "/").first else {
                continue
            }
            return normalizedAppName(String(first))
        }
        return nil
    }

    private func normalizedAppName(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".app") {
            name.removeLast(4)
        }
        if name.lowercased().contains("cyolo") {
            return "Cyolo"
        }
        return name
    }

    private func isInsideHome(_ path: String) -> Bool {
        path == homeDirectory || path.hasPrefix(homeDirectory + "/")
    }

    private func hasPrefix(_ path: String, in prefixes: [String]) -> Bool {
        prefixes.contains { path.hasPrefix($0) }
    }

    private func standardizedPath(_ path: String) -> String {
        guard !path.isEmpty else {
            return path
        }
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func fileIdentity(_ path: String) -> FileIdentity {
        let standardized = standardizedPath(path)
        var info = stat()
        guard !standardized.isEmpty, Darwin.lstat(standardized, &info) == 0 else {
            return FileIdentity(
                path: standardized,
                device: nil,
                inode: nil,
                modifiedSeconds: nil,
                modifiedNanoseconds: nil,
                size: nil
            )
        }
        return FileIdentity(
            path: standardized,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            size: Int64(info.st_size)
        )
    }
}
