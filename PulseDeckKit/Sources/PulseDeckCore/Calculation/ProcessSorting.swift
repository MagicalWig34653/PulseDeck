import Foundation

/// Sorting of the process table. `sorted(using: [KeyPathComparator])` reads every key through
/// dynamic key-path access on each comparison, which took ~6 ms per tick for ~600 rows (M10).
/// Here each row's key is read once and indices are sorted; ties fall back to the PID so rows
/// with equal values (most processes at 0.0 % CPU) keep a stable order between updates.
public enum ProcessSorting {
    public static func sorted(_ processes: [ProcessSnapshot], by comparator: KeyPathComparator<ProcessSnapshot>?) -> [ProcessSnapshot] {
        guard let comparator else { return processes }
        let ascending = comparator.order == .forward
        let path = comparator.keyPath
        if path == \ProcessSnapshot.name {
            return processes.sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order == .orderedSame { return lhs.pid < rhs.pid }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
        if path == \ProcessSnapshot.pid { return sorted(processes, ascending: ascending) { $0.pid } }
        if path == \ProcessSnapshot.cpuSortValue { return sorted(processes, ascending: ascending) { $0.cpuSortValue } }
        if path == \ProcessSnapshot.memorySortValue { return sorted(processes, ascending: ascending) { $0.memorySortValue } }
        if path == \ProcessSnapshot.threadSortValue { return sorted(processes, ascending: ascending) { $0.threadSortValue } }
        if path == \ProcessSnapshot.diskReadSortValue { return sorted(processes, ascending: ascending) { $0.diskReadSortValue } }
        if path == \ProcessSnapshot.diskWriteSortValue { return sorted(processes, ascending: ascending) { $0.diskWriteSortValue } }
        return processes.sorted(using: comparator)
    }

    private static func sorted<Key: Comparable>(_ processes: [ProcessSnapshot], ascending: Bool, by key: (ProcessSnapshot) -> Key) -> [ProcessSnapshot] {
        let keys = processes.map(key)
        let order = processes.indices.sorted { lhs, rhs in
            if keys[lhs] == keys[rhs] { return processes[lhs].pid < processes[rhs].pid }
            return ascending ? keys[lhs] < keys[rhs] : keys[lhs] > keys[rhs]
        }
        return order.map { processes[$0] }
    }
}

extension ProcessSnapshot {
    // Sort keys. Missing values sort below every real value; they are never displayed.
    public var cpuSortValue: Double { cpu.value ?? -1 }
    public var memorySortValue: Int64 { memoryBytes.value.map { Int64(clamping: $0) } ?? -1 }
    public var threadSortValue: Int { threadCount.value ?? -1 }
    public var diskReadSortValue: Double { diskReadBytesPerSecond.value ?? -1 }
    public var diskWriteSortValue: Double { diskWriteBytesPerSecond.value ?? -1 }

    /// Search: name or path contains the query, or the query is the PID.
    public func matches(_ query: String) -> Bool {
        name.localizedStandardContains(query)
            || String(pid) == query
            || (path?.localizedStandardContains(query) ?? false)
    }
}
