import Foundation

/// A vendor command to run once (a user clicked Start, Stop or Apply). Built by pure functions in
/// this module and executed by the telemetry module's `VMCommandRunner`: no shell, an explicit
/// executable and an argument array, a timeout.
public struct VMCommandPlan: Hashable, Sendable {
    /// Candidate executables, tried in order: absolute paths or bare names looked up in
    /// `VMToolLocator.searchDirectories`.
    public var tool: [String]
    public var arguments: [String]
    public var timeout: Duration
    /// Shown in error messages ("limactl stop colima").
    public var title: String
    /// Extra environment variables on top of `VMToolLocator.childEnvironment` (e.g. `LIMA_HOME`).
    public var environment: [String: String]

    public init(tool: [String], arguments: [String], timeout: Duration, title: String? = nil, environment: [String: String] = [:]) {
        self.tool = tool
        self.arguments = arguments
        self.timeout = timeout
        self.environment = environment
        self.title = title ?? ((tool.first.map { ($0 as NSString).lastPathComponent } ?? "command") + " " + arguments.joined(separator: " "))
    }
}

/// Where vendor command-line tools live on a Mac and what environment they need.
///
/// A GUI app has a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so Homebrew, `~/.local/bin`
/// and application bundles are searched explicitly. The same directories form the child's `PATH`:
/// vendor tools run siblings (Colima → `limactl` → `qemu-system-*`; Rancher's `rdctl`).
public enum VMToolLocator {
    /// Homebrew (Apple silicon, Intel), per-user and application-bundle locations.
    public static func searchDirectories(home: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            home + "/.local/bin",
            home + "/.orbstack/bin",
            home + "/.rd/bin",
            home + "/.docker/bin",
            home + "/bin",
            "/Applications/OrbStack.app/Contents/MacOS/xbin",
            "/Applications/Rancher Desktop.app/Contents/Resources/resources/darwin/bin",
            "/Applications/Docker.app/Contents/Resources/bin",
            "/Applications/Finch/bin",
            "/Applications/Finch/lima/bin",
            "/Applications/Parallels Desktop.app/Contents/MacOS",
            "/Applications/VMware Fusion.app/Contents/Public",
            "/Applications/UTM.app/Contents/MacOS",
            "/usr/local/bin/anka",
        ]
    }

    /// Absolute paths to try for each candidate, in order. Absolute candidates (and `~/…`) are used
    /// as given; bare names are searched in every directory.
    public static func resolvedCandidates(_ candidates: [String], home: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let directories = searchDirectories(home: home)
        for candidate in candidates where !candidate.isEmpty {
            var paths: [String]
            if candidate.hasPrefix("/") {
                paths = [candidate]
            } else if candidate.hasPrefix("~/") {
                paths = [home + String(candidate.dropFirst())]
            } else if candidate.contains("/") {
                // A relative path with directories is ambiguous: ignore it.
                paths = []
            } else {
                paths = directories.map { $0 + "/" + candidate }
            }
            paths.removeAll { !seen.insert($0).inserted }
            result.append(contentsOf: paths)
        }
        return result
    }

    /// The environment of a vendor tool process: minimal, deterministic, English output.
    public static func childEnvironment(home: String, userName: String, temporaryDirectory: String) -> [String: String] {
        [
            "HOME": home,
            "USER": userName,
            "LOGNAME": userName,
            "PATH": searchDirectories(home: home).joined(separator: ":"),
            "LANG": "C",
            "LC_ALL": "C",
            "TMPDIR": temporaryDirectory,
        ]
    }
}

/// Dotted version numbers of installed tools (`1.2.3`, `v2.0.0-beta.1`, `4.38.0`).
public struct VMVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var components: [Int]

    /// Parses the leading `major.minor.patch…` run of digits; anything after it (`-rc1`, `_1`) is ignored.
    public init?(_ text: String) {
        var trimmed = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed = trimmed.dropFirst() }
        var parsed: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            parsed.append(value)
            // "1.2.3-rc1": a suffix on this component ends the version.
            if digits.count != part.count { break }
        }
        guard !parsed.isEmpty else { return nil }
        components = parsed
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: VMVersion, rhs: VMVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: VMVersion, rhs: VMVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hash(into hasher: inout Hasher) {
        // Trailing zeros do not matter for equality (1.2 == 1.2.0).
        var significant = components
        while significant.last == 0 { significant.removeLast() }
        hasher.combine(significant)
    }

    /// The highest version among directory names such as Homebrew's `Cellar/lima/1.1.1`.
    public static func newest(in names: [String]) -> VMVersion? {
        names.compactMap(VMVersion.init).max()
    }
}
