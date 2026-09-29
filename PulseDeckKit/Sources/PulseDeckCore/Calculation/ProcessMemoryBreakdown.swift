/// Memory use split by process for the Memory page's pie chart: the largest consumers plus one
/// "other processes" slice, at most `maximumSlices` in total.
///
/// Processes are grouped by name, so an app's many helper processes of the same name (browser
/// renderers, for example) form one slice. Processes whose memory is unknown — macOS withholds it
/// for other users' processes — are counted separately, never guessed.
public struct ProcessMemoryBreakdown: Hashable, Sendable {
    public struct Slice: Hashable, Sendable, Identifiable {
        /// Process name; for the remainder slice, `nil`.
        public var name: String?
        public var bytes: UInt64
        /// Processes combined in this slice.
        public var processCount: Int

        public var id: String { name ?? "" }
        public var isOther: Bool { name == nil }

        public init(name: String?, bytes: UInt64, processCount: Int) {
            self.name = name
            self.bytes = bytes
            self.processCount = processCount
        }
    }

    /// Largest first; the remainder slice (if any) last.
    public var slices: [Slice]
    /// Sum over all processes with a known footprint.
    public var totalBytes: UInt64
    /// Processes left out because their memory is not available.
    public var excludedProcessCount: Int

    public static let defaultMaximumSlices = 6

    public init(processes: [ProcessSnapshot], maximumSlices: Int = defaultMaximumSlices) {
        var groups: [String: (bytes: UInt64, count: Int)] = [:]
        var excluded = 0
        for process in processes {
            guard let bytes = process.memoryBytes.value else {
                excluded += 1
                continue
            }
            groups[process.name, default: (0, 0)].bytes &+= bytes
            groups[process.name, default: (0, 0)].count += 1
        }
        let sorted = groups
            .map { Slice(name: $0.key, bytes: $0.value.bytes, processCount: $0.value.count) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : ($0.name ?? "") < ($1.name ?? "") }

        let limit = max(maximumSlices, 1)
        var slices: [Slice]
        if sorted.count <= limit {
            slices = sorted
        } else {
            // One slot goes to the remainder.
            slices = Array(sorted.prefix(limit - 1))
            let rest = sorted.dropFirst(limit - 1)
            slices.append(Slice(
                name: nil,
                bytes: rest.reduce(0) { $0 &+ $1.bytes },
                processCount: rest.reduce(0) { $0 + $1.processCount }
            ))
        }
        self.slices = slices
        totalBytes = sorted.reduce(0) { $0 &+ $1.bytes }
        excludedProcessCount = excluded
    }
}
