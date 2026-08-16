import Darwin
import Foundation

public enum JobProvenance: Hashable {
    case yours
    /// Ticker's own login item. Shown honestly, but Ticker never raises an
    /// alert about itself: if Ticker is not running there is nobody to alert.
    case ticker
    case app(String)
    case packageManager(String)
    case system
    case unknown(String)

    public var kind: String {
        switch self {
        case .yours:
            return "yours"
        case .ticker:
            return "ticker"
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
        case .ticker:
            return "Ticker"
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

    public var isAttentionOwned: Bool {
        switch self {
        case .yours, .unknown:
            return true
        case .ticker, .app, .packageManager, .system:
            return false
        }
    }

    public var isConfirmedThirdParty: Bool {
        !isAttentionOwned
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
        case "ticker":
            self = .ticker
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
        case .yours, .ticker, .system:
            break
        }
    }
}

public enum JobAttention: Hashable {
    case missingPayload(String)
    case malformedConfiguration(path: String, message: String)
    case inertConfiguration(path: String, message: String)
    case unreadableConfiguration(path: String, message: String)

    public var kind: String {
        switch self {
        case .missingPayload:
            return "missingPayload"
        case .malformedConfiguration:
            return "malformedConfiguration"
        case .inertConfiguration:
            return "inertConfiguration"
        case .unreadableConfiguration:
            return "unreadableConfiguration"
        }
    }

    public var path: String {
        switch self {
        case .missingPayload(let path):
            return path
        case .malformedConfiguration(let path, _),
             .inertConfiguration(let path, _),
             .unreadableConfiguration(let path, _):
            return path
        }
    }

    public var summary: String {
        switch self {
        case .missingPayload:
            return "Missing payload"
        case .malformedConfiguration:
            return "Malformed configuration"
        case .inertConfiguration:
            return "Inert configuration"
        case .unreadableConfiguration:
            return "Unreadable configuration"
        }
    }

    public var requiresAttention: Bool {
        switch self {
        case .missingPayload, .malformedConfiguration:
            return true
        case .inertConfiguration, .unreadableConfiguration:
            return false
        }
    }

    public var isConfigurationDiagnostic: Bool {
        switch self {
        case .missingPayload:
            return false
        case .malformedConfiguration, .inertConfiguration, .unreadableConfiguration:
            return true
        }
    }

    public var detail: String {
        switch self {
        case .missingPayload(let path):
            return "The job's payload does not exist at \(path)."
        case .malformedConfiguration(let path, let message):
            return "Ticker found \(path), but it is not a valid property list: \(message)"
        case .inertConfiguration(let path, let message):
            return "\(path) is a valid property list, but it does not declare a runnable launchd job: \(message). It is inert and will not run."
        case .unreadableConfiguration(let path, let message):
            return "Ticker cannot inspect \(path) without elevated access: \(message)"
        }
    }

    public var diagnosticDescription: String {
        switch self {
        case .missingPayload(let path):
            return "missing payload at \(path)"
        case .malformedConfiguration(let path, let message):
            return "malformed configuration at \(path): \(message)"
        case .inertConfiguration(let path, let message):
            return "inert configuration at \(path): \(message)"
        case .unreadableConfiguration(let path, let message):
            return "unreadable configuration at \(path): elevated access is required (\(message))"
        }
    }
}

extension JobAttention: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "missingPayload":
            self = .missingPayload(try container.decode(String.self, forKey: .path))
        case "malformedConfiguration":
            self = .malformedConfiguration(
                path: try container.decode(String.self, forKey: .path),
                message: try container.decode(String.self, forKey: .message)
            )
        case "inertConfiguration":
            self = .inertConfiguration(
                path: try container.decode(String.self, forKey: .path),
                message: try container.decode(String.self, forKey: .message)
            )
        case "unreadableConfiguration":
            self = .unreadableConfiguration(
                path: try container.decode(String.self, forKey: .path),
                message: try container.decode(String.self, forKey: .message)
            )
        case "missingCommand":
            self = .inertConfiguration(
                path: try container.decode(String.self, forKey: .path),
                message: "the plist does not define Program or ProgramArguments"
            )
        case "brokenConfiguration":
            self = .malformedConfiguration(
                path: try container.decode(String.self, forKey: .path),
                message: try container.decode(String.self, forKey: .message)
            )
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
        switch self {
        case .malformedConfiguration(_, let message),
             .inertConfiguration(_, let message),
             .unreadableConfiguration(_, let message):
            try container.encode(message, forKey: .message)
        case .missingPayload:
            break
        }
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
        let workingDirectory: String?
        let environment: [String]
    }

    private struct CacheEntry {
        let key: CacheKey
        let resolution: LaunchdResolution
    }

    private struct LaunchdResolution {
        let provenance: JobProvenance
        let payload: String?
    }

    private enum InterpreterKind {
        case shell
        case python
        case ruby
        case perl
        case node
        case osascript
        case open
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
        "/Library/Scripts/Videostream/",
        "/var/lib/",
    ]

    private static let systemPrefixes = [
        "/System/",
        "/usr/libexec/",
        "/usr/bin/",
        "/usr/sbin/",
        "/bin/",
        "/sbin/",
    ]

    private static let shellNames: Set<String> = [
        "bash", "dash", "fish", "ksh", "sh", "tcsh", "zsh",
    ]

    private static let reverseDNSRoots: Set<String> = [
        "ai", "app", "co", "com", "dev", "io", "me", "net", "org",
    ]

    private static let filenameVendorDisplayNames = [
        "google": "Google",
        "island": "Island",
        "microsoft": "Microsoft",
    ]

    private static let tickerLoginLabel = "com.suchintan.ticker.login"
    private static let installedTickerExecutable = "/Applications/Ticker.app/Contents/MacOS/Ticker"

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
    private let resolvedHomeDirectory: String
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
        self.resolvedHomeDirectory = homeDirectory.standardizedFileURL
            .resolvingSymlinksInPath().path
        self.codesignURL = codesignURL
        self.fileManager = fileManager
        self.signatureRunner = signatureRunner
    }

    /// True only for Ticker's exact parsed launchd identity. The effective
    /// executable is the literal `Program`, or `ProgramArguments[0]` only when
    /// `Program` is absent. It is intentionally separate from the logical
    /// command because a Ticker wrapper can be unwrapped for display.
    internal func isTickerItself(
        launchdLabel: String?,
        effectiveExecutable: String?
    ) -> Bool {
        launchdLabel == Self.tickerLoginLabel
            && effectiveExecutable == Self.installedTickerExecutable
    }

    internal func classify(
        source: JobSource,
        command: [String],
        configPath: String?,
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        launchdLabel: String? = nil,
        effectiveExecutable: String? = nil
    ) -> JobClassification {
        guard source == .launchd else {
            return JobClassification(provenance: .yours, attention: nil)
        }

        // Ticker's own login item. Recognised before any vendor rule so it is
        // never filed as third-party software just because it lives in
        // /Applications, and so it can never alert about itself.
        if isTickerItself(
            launchdLabel: launchdLabel,
            effectiveExecutable: effectiveExecutable
        ) {
            return JobClassification(provenance: .ticker, attention: nil)
        }

        let program = command.first ?? ""
        let resolvedProgram = resolvedPath(
            program,
            workingDirectory: workingDirectory,
            environment: environment,
            searchPath: true
        ) ?? standardizedPath(program)
        let cacheSlot = configPath ?? "unidentified:\(command.joined(separator: "\u{1f}"))"
        let key = CacheKey(
            plist: fileIdentity(configPath ?? cacheSlot),
            program: fileIdentity(resolvedProgram),
            command: command,
            workingDirectory: workingDirectory,
            environment: environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        )

        let resolution: LaunchdResolution
        lock.lock()
        if let entry = cache[cacheSlot], entry.key == key {
            resolution = entry.resolution
            lock.unlock()
        } else {
            lock.unlock()
            resolution = classifyLaunchd(
                command: command,
                configPath: configPath,
                workingDirectory: workingDirectory,
                environment: environment
            )
            lock.lock()
            cache[cacheSlot] = CacheEntry(key: key, resolution: resolution)
            lock.unlock()
        }

        let attention: JobAttention?
        if command.isEmpty {
            attention = .inertConfiguration(
                path: configPath ?? "launchd configuration",
                message: "the plist does not define Program or ProgramArguments"
            )
        } else {
            attention = resolution.payload.flatMap { path -> JobAttention? in
            let standardized = standardizedPath(path)
            return fileManager.fileExists(atPath: standardized)
                ? nil
                : .missingPayload(standardized)
            }
        }
        return JobClassification(
            provenance: resolution.provenance,
            attention: attention
        )
    }

    internal func classifyConfiguration(at path: String) -> JobProvenance {
        if let vendor = filenameVendorName(for: path) {
            return .app(vendor)
        }
        return isInsideHome(path)
            ? .yours
            : .unknown("could not attribute launchd configuration \(standardizedPath(path))")
    }

    private func classifyLaunchd(
        command: [String],
        configPath: String?,
        workingDirectory: String?,
        environment: [String: String]
    ) -> LaunchdResolution {
        guard let program = command.first, !program.isEmpty else {
            let provenance = configPath.map(classifyConfiguration(at:))
                ?? .unknown("launchd job has no program")
            return LaunchdResolution(provenance: provenance, payload: nil)
        }

        let programPath = resolvedPath(
            program,
            workingDirectory: workingDirectory,
            environment: environment,
            searchPath: true
        ) ?? standardizedPath(program)
        if let interpreter = interpreterKind(for: programPath),
           let payload = interpreterPayload(
               kind: interpreter,
               arguments: Array(command.dropFirst()),
               workingDirectory: workingDirectory,
               environment: environment
           ) {
            return LaunchdResolution(
                provenance: provenanceForPayload(payload),
                payload: payload
            )
        }
        if interpreterKind(for: programPath) != nil {
            return LaunchdResolution(
                provenance: .unknown("interpreter command has no attributable file payload"),
                payload: nil
            )
        }

        return LaunchdResolution(
            provenance: provenanceForExecutable(programPath),
            payload: programPath.hasPrefix("/") ? programPath : nil
        )
    }

    private func developerIDAuthority(for program: String) -> String? {
        guard let verification = try? signatureRunner(
            codesignURL,
            ["--verify", "--strict", "--verbose=4", program]
        ), verification.status == 0 else {
            return nil
        }
        if let authority = signatureAuthority(from: verification) {
            return authority
        }
        guard let display = try? signatureRunner(
            codesignURL,
            ["-dv", "--verbose=4", program]
        ), display.status == 0 else {
            return nil
        }
        return signatureAuthority(from: display)
    }

    private func signatureAuthority(from result: AdapterCommandResult) -> String? {
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

    private func provenanceForPayload(_ path: String) -> JobProvenance {
        let standardized = standardizedPath(path)
        if isInsideHome(standardized) {
            return .yours
        }
        if let packageManager = packageManagerName(for: standardized) {
            return .packageManager(packageManager)
        }
        if let name = vendorName(for: standardized) {
            return .app(name)
        }
        if hasPrefix(standardized, in: Self.systemPrefixes) {
            return .system
        }
        return .unknown("could not attribute payload \(standardized)")
    }

    private func provenanceForExecutable(_ path: String) -> JobProvenance {
        let standardized = standardizedPath(path)
        if let packageManager = packageManagerName(for: standardized) {
            return .packageManager(packageManager)
        }
        if standardized.hasPrefix("/"),
           let authority = developerIDAuthority(for: standardized) {
            return .app(normalizedAppName(authority))
        }
        if let name = vendorName(for: standardized) {
            return .app(name)
        }
        if hasPrefix(standardized, in: Self.systemPrefixes) {
            return .system
        }
        if isInsideHome(standardized) {
            return .yours
        }
        return .unknown("could not attribute \(path)")
    }

    private func packageManagerName(for path: String) -> String? {
        if path.hasPrefix("/opt/local/") {
            return "MacPorts"
        }
        return hasPrefix(path, in: Self.packageManagerPrefixes) ? "Homebrew" : nil
    }

    private func interpreterKind(for path: String) -> InterpreterKind? {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if Self.shellNames.contains(name) {
            return .shell
        }
        if name.hasPrefix("python") {
            return .python
        }
        if name == "ruby" || name.hasPrefix("ruby") {
            return .ruby
        }
        if name == "perl" || name.hasPrefix("perl") {
            return .perl
        }
        if name == "node" || name.hasPrefix("node") {
            return .node
        }
        if name == "osascript" {
            return .osascript
        }
        if name == "open" {
            return .open
        }
        return nil
    }

    private func interpreterPayload(
        kind: InterpreterKind,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String]
    ) -> String? {
        let rawPayload: String?
        switch kind {
        case .shell:
            if let commandIndex = arguments.firstIndex(where: {
                $0 == "--command" || ($0.hasPrefix("-") && $0.dropFirst().contains("c"))
            }) {
                guard commandIndex + 1 < arguments.count else {
                    return nil
                }
                guard let executable = shellCommandExecutable(arguments[commandIndex + 1]),
                      executable.hasPrefix("/")
                        || executable.hasPrefix("~")
                        || executable.hasPrefix("$")
                        || executable.contains("/") else {
                    return nil
                }
                rawPayload = executable
            } else {
                rawPayload = firstFileArgument(
                    in: arguments,
                    inlineOptions: [],
                    optionsWithValues: ["-o", "+o", "--rcfile"]
                )
            }
        case .python:
            rawPayload = firstFileArgument(
                in: arguments,
                inlineOptions: ["-c", "-m", "--command", "--module"],
                optionsWithValues: ["-W", "-X", "--check-hash-based-pycs"]
            )
        case .ruby, .perl:
            rawPayload = firstFileArgument(
                in: arguments,
                inlineOptions: ["-e"],
                optionsWithValues: ["-C", "-I", "-M", "-m", "-r", "--encoding"]
            )
        case .node:
            rawPayload = firstFileArgument(
                in: arguments,
                inlineOptions: ["-e", "--eval", "-p", "--print"],
                optionsWithValues: [
                    "-r", "--conditions", "--import", "--loader", "--require",
                ]
            )
        case .osascript:
            rawPayload = firstFileArgument(
                in: arguments,
                inlineOptions: ["-e"],
                optionsWithValues: ["-l", "--language"]
            )
        case .open:
            rawPayload = firstFileArgument(
                in: arguments,
                inlineOptions: [],
                optionsWithValues: ["-a", "-b", "--application", "--bundle-identifier"]
            )
        }
        guard let rawPayload, !rawPayload.contains("://") else {
            return nil
        }
        return resolvedPath(
            rawPayload,
            workingDirectory: workingDirectory,
            environment: environment,
            searchPath: false
        )
    }

    private func firstFileArgument(
        in arguments: [String],
        inlineOptions: Set<String>,
        optionsWithValues: Set<String>
    ) -> String? {
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if inlineOptions.contains(argument) {
                return nil
            }
            if optionsWithValues.contains(argument) {
                skipNext = true
                continue
            }
            if optionsWithValues.contains(where: { argument.hasPrefix($0 + "=") }) {
                continue
            }
            if argument == "--" {
                continue
            }
            if !argument.hasPrefix("-") {
                return argument
            }
        }
        return nil
    }

    private func shellCommandExecutable(_ command: String) -> String? {
        let words = shellWords(command)
        var index = 0
        while index < words.count {
            let word = words[index]
            if word == "exec" || word == "command" || word == "source" || word == "." {
                index += 1
                continue
            }
            if word == "env" || word.contains("=") {
                index += 1
                continue
            }
            if word.hasPrefix("-") {
                index += 1
                continue
            }
            return word
        }
        return nil
    }

    private func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                word.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    word.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !word.isEmpty {
                    words.append(word)
                    word = ""
                }
            } else if character == ";" || character == "|" || character == "&" {
                if !word.isEmpty {
                    words.append(word)
                    word = ""
                }
                break
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty {
            words.append(word)
        }
        return words
    }

    private func resolvedPath(
        _ rawPath: String,
        workingDirectory: String?,
        environment: [String: String],
        searchPath: Bool
    ) -> String? {
        guard !rawPath.isEmpty else {
            return nil
        }
        let expanded = expandPathVariables(rawPath, environment: environment)
        if expanded.hasPrefix("/") {
            return standardizedPath(expanded)
        }
        if expanded.contains("/") || !searchPath {
            let base = workingDirectory.map {
                expandPathVariables($0, environment: environment)
            } ?? "/"
            return URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(expanded)
                .standardizedFileURL.path
        }
        let searchDirectories = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        for directory in searchDirectories {
            let base = directory.isEmpty ? (workingDirectory ?? "/") : directory
            let candidate = URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(expanded)
                .standardizedFileURL.path
            if fileManager.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return expanded
    }

    private func expandPathVariables(
        _ rawPath: String,
        environment: [String: String]
    ) -> String {
        var values = environment
        values["HOME"] = environment["HOME"] ?? homeDirectory
        var path = rawPath
        if path == "~" {
            path = values["HOME"] ?? homeDirectory
        } else if path.hasPrefix("~/") {
            path = (values["HOME"] ?? homeDirectory) + String(path.dropFirst())
        }
        for key in values.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = values[key] else {
                continue
            }
            path = path.replacingOccurrences(of: "${\(key)}", with: value)
            path = path.replacingOccurrences(of: "$\(key)", with: value)
        }
        return path
    }

    private func vendorName(for path: String) -> String? {
        guard !hasPrefix(path, in: Self.packageManagerPrefixes) else {
            return nil
        }
        let userApplicationSupport = homeDirectory + "/Library/Application Support/"
        if path.hasPrefix(userApplicationSupport) {
            let remainder = path.dropFirst(userApplicationSupport.count)
            return remainder.split(separator: "/").first.map {
                normalizedAppName(String($0))
            }
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

    private func filenameVendorName(for path: String) -> String? {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let lowercaseFilename = filename.lowercased()
        guard let plistRange = lowercaseFilename.range(of: ".plist") else {
            return nil
        }
        let stem = String(lowercaseFilename[..<plistRange.lowerBound])
        let segments = stem.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 3,
              Self.reverseDNSRoots.contains(String(segments[0])) else {
            return nil
        }

        let vendor = String(segments[1])
        let validVendorCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_"))
        guard !vendor.isEmpty,
              vendor.unicodeScalars.allSatisfy(validVendorCharacters.contains),
              !ownerFilenameSegments.contains(vendor) else {
            return nil
        }
        if let displayName = Self.filenameVendorDisplayNames[vendor] {
            return displayName
        }
        return vendor
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { String($0).capitalized }
            .joined(separator: " ")
    }

    private var ownerFilenameSegments: Set<String> {
        Set([
            URL(fileURLWithPath: homeDirectory).lastPathComponent,
            NSUserName(),
            ProcessInfo.processInfo.environment["USER"] ?? "",
        ].map { $0.lowercased() }.filter { !$0.isEmpty })
    }

    private func isInsideHome(_ path: String) -> Bool {
        let standardized = standardizedPath(path)
        if standardized == homeDirectory || standardized.hasPrefix(homeDirectory + "/") {
            return true
        }
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        return resolved == resolvedHomeDirectory
            || resolved.hasPrefix(resolvedHomeDirectory + "/")
    }

    private func hasPrefix(_ path: String, in prefixes: [String]) -> Bool {
        prefixes.contains { path.hasPrefix($0) }
    }

    private func standardizedPath(_ path: String) -> String {
        guard !path.isEmpty else {
            return path
        }
        let expanded: String
        if path == "~" {
            expanded = homeDirectory
        } else if path.hasPrefix("~/") {
            expanded = homeDirectory + String(path.dropFirst())
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func fileIdentity(_ path: String) -> FileIdentity {
        let standardized = standardizedPath(path)
        let identityPath = URL(fileURLWithPath: standardized)
            .resolvingSymlinksInPath().path
        var info = stat()
        guard !standardized.isEmpty, Darwin.lstat(identityPath, &info) == 0 else {
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
