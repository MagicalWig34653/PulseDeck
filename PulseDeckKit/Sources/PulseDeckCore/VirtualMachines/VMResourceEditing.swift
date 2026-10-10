/// Checks a requested resource change against what the provider allows, before any command runs.
public enum VMResourceEditing {
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case invalidCPUs
        case invalidMemory
        case invalidDisk
        /// Virtual disks can be enlarged but not shrunk.
        case diskCannotShrink
        /// The provider does not let PulseDeck change this value.
        case notEditable(String)

        public var description: String {
            switch self {
            case .invalidCPUs: "The number of CPUs must be at least 1."
            case .invalidMemory: "The memory size must be greater than zero."
            case .invalidDisk: "The disk size must be greater than zero."
            case .diskCannotShrink: "The disk can only be made larger, not smaller."
            case .notEditable(let what): "\(what) cannot be changed for this virtual machine."
            }
        }
    }

    /// The fields of `requested` that differ from `current` (all others are `nil`), after
    /// validation. An empty result (`VMResources()`) means there is nothing to do.
    public static func changes(requested: VMResources, current: VMResources, capabilities: VMCapabilities) -> Result<VMResources, Problem> {
        var changes = VMResources()
        if let cpus = requested.cpus, cpus != current.cpus {
            guard cpus >= 1 else { return .failure(.invalidCPUs) }
            guard capabilities.canEditCPUs else { return .failure(.notEditable("The number of CPUs")) }
            changes.cpus = cpus
        }
        if let memory = requested.memoryBytes, memory != current.memoryBytes {
            guard memory > 0 else { return .failure(.invalidMemory) }
            guard capabilities.canEditMemory else { return .failure(.notEditable("The memory size")) }
            changes.memoryBytes = memory
        }
        if let disk = requested.diskBytes, disk != current.diskBytes {
            guard disk > 0 else { return .failure(.invalidDisk) }
            guard capabilities.canEditDisk else { return .failure(.notEditable("The disk size")) }
            if capabilities.diskCanOnlyGrow, let existing = current.diskBytes, disk < existing {
                return .failure(.diskCannotShrink)
            }
            changes.diskBytes = disk
        }
        return .success(changes)
    }

    public static func isEmpty(_ changes: VMResources) -> Bool {
        changes.cpus == nil && changes.memoryBytes == nil && changes.diskBytes == nil
    }
}
