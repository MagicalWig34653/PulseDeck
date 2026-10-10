import Foundation

/// The values being edited in the VM resource editor, with the rules that decide what may be
/// edited, what the controls allow and which values are sent to the provider. Platform-independent
/// so the rules are tested without the UI.
///
/// Memory and disk are edited in whole GiB (what the VM tools use); CPUs in whole processors.
/// Only values the user changed are part of `changes`, so a provider never receives a value that
/// merely went through rounding.
public struct VMResourceDraft: Equatable, Sendable {
    public static let bytesPerGiB: UInt64 = 1 << 30
    /// Above this share of the Mac's memory the editor warns that macOS itself will struggle.
    public static let memoryCautionFraction = 0.75
    /// Upper end of the disk field. A sanity bound for typing mistakes, not a provider limit.
    public static let maximumDiskGiB = 16_384

    public let capabilities: VMCapabilities
    public let hostCPUs: Int
    public let hostMemoryBytes: UInt64
    /// Configured values as the provider reported them, in editor units. `nil` if not reported;
    /// such a value cannot be edited (its current value is unknown).
    public let initialCPUs: Int?
    public let initialMemoryGiB: Int?
    public let initialDiskGiB: Int?

    public var cpus: Int
    public var memoryGiB: Int
    public var diskGiB: Int

    public init(original: VMResources, capabilities: VMCapabilities, hostCPUs: Int, hostMemoryBytes: UInt64) {
        self.capabilities = capabilities
        self.hostCPUs = max(hostCPUs, 1)
        self.hostMemoryBytes = hostMemoryBytes
        initialCPUs = original.cpus.map { max($0, 1) }
        initialMemoryGiB = original.memoryBytes.map { Self.gibibytes($0, roundingUp: false) }
        // Rounded up so a grow-only disk never starts below its real size.
        initialDiskGiB = original.diskBytes.map { Self.gibibytes($0, roundingUp: true) }
        cpus = initialCPUs ?? 1
        memoryGiB = initialMemoryGiB ?? 1
        diskGiB = initialDiskGiB ?? 1
    }

    static func gibibytes(_ bytes: UInt64, roundingUp: Bool) -> Int {
        let exact = Double(bytes) / Double(bytesPerGiB)
        return max(Int((roundingUp ? exact.rounded(.up) : exact.rounded()).clamped(to: 0...Double(Int32.max))), 1)
    }

    // MARK: - What may be edited

    public var canEditCPUs: Bool { capabilities.canEditCPUs && initialCPUs != nil }
    public var canEditMemory: Bool { capabilities.canEditMemory && initialMemoryGiB != nil }
    public var canEditDisk: Bool { capabilities.canEditDisk && initialDiskGiB != nil }
    public var canEditAnything: Bool { canEditCPUs || canEditMemory || canEditDisk }

    // MARK: - Ranges offered by the controls

    /// 1 … the Mac's logical processors (or the current value if the VM already has more).
    public var cpuRange: ClosedRange<Int> {
        1...max(hostCPUs, initialCPUs ?? 1)
    }

    public var hostMemoryGiB: Int {
        max(Int(hostMemoryBytes / Self.bytesPerGiB), 1)
    }

    /// 1 GiB … the Mac's memory minus one GiB, which macOS needs at the very least (or the
    /// current value if the VM already has more).
    public var memoryRange: ClosedRange<Int> {
        1...max(hostMemoryGiB - 1, initialMemoryGiB ?? 1, 1)
    }

    /// The current size … `maximumDiskGiB` if disks can only grow; 1 … `maximumDiskGiB` otherwise.
    public var diskRange: ClosedRange<Int> {
        let lower = capabilities.diskCanOnlyGrow ? (initialDiskGiB ?? 1) : 1
        return lower...max(Self.maximumDiskGiB, lower)
    }

    // MARK: - Validation

    public var memoryBytes: UInt64 { UInt64(max(memoryGiB, 0)) * Self.bytesPerGiB }
    public var diskBytes: UInt64 { UInt64(max(diskGiB, 0)) * Self.bytesPerGiB }

    /// Memory share of the Mac's memory, 0…1+.
    public var memoryFractionOfHost: Double {
        hostMemoryBytes > 0 ? Double(memoryBytes) / Double(hostMemoryBytes) : 0
    }

    /// The VM's memory would take most of the Mac's memory.
    public var exceedsMemoryCaution: Bool {
        memoryFractionOfHost > Self.memoryCautionFraction
    }

    public enum DiskIssue: Equatable, Sendable {
        /// The size is below the current one, and the disk can only be enlarged.
        case cannotShrink(minimumGiB: Int)
        case outOfRange
    }

    public var diskIssue: DiskIssue? {
        guard canEditDisk, !diskRange.contains(diskGiB) else { return nil }
        if capabilities.diskCanOnlyGrow, diskGiB < diskRange.lowerBound {
            return .cannotShrink(minimumGiB: diskRange.lowerBound)
        }
        return .outOfRange
    }

    /// Every editable value is inside its range.
    public var isValid: Bool {
        (!canEditCPUs || cpuRange.contains(cpus))
            && (!canEditMemory || memoryRange.contains(memoryGiB))
            && (!canEditDisk || diskIssue == nil)
    }

    // MARK: - Result

    /// Only the editable values the user changed; everything else stays `nil`.
    public var changes: VMResources {
        VMResources(
            cpus: canEditCPUs && cpus != initialCPUs ? cpus : nil,
            memoryBytes: canEditMemory && memoryGiB != initialMemoryGiB ? memoryBytes : nil,
            diskBytes: canEditDisk && diskGiB != initialDiskGiB ? diskBytes : nil
        )
    }

    public var hasChanges: Bool {
        changes != VMResources()
    }

    public var canApply: Bool { isValid && hasChanges }

    // MARK: - Plan

    public enum ApplyPlan: Equatable, Sendable {
        /// Apply directly: the VM is stopped (or not running), or the provider edits live.
        case applyNow
        /// The provider only edits stopped VMs and this one is running: stop it, apply, start it.
        case stopApplyAndStart
        /// The VM is starting or stopping; changes would race with that.
        case waitForTransition
    }

    public func plan(for state: VMState) -> ApplyPlan {
        switch state {
        case .starting, .stopping:
            .waitForTransition
        case .running, .paused:
            capabilities.editRequiresStopped ? .stopApplyAndStart : .applyNow
        case .stopped, .suspended, .unknown:
            .applyNow
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
