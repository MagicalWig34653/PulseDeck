#if os(macOS)
import Foundation
import PulseDeckCore

/// Virtual machines of the VM programs installed on this Mac, with host-side resource use.
///
/// Per tick:
/// 1. one snapshot of the VM-relevant host processes (`VMHostProcessTable`);
/// 2. for every adapter of `VMProviderRegistry`: `detect` (cached, repeated every 30 s) and, for the
///    installed ones, `list` — concurrently, because a listing may take a moment. Adapters that must
///    run a vendor command to list (`minimumListInterval` above zero) are called at most that often;
///    in between their previous records are reused while usage keeps refreshing from the process
///    table;
/// 3. per VM, the cumulative usage of its host processes (`hostProcessIDs`) goes through
///    `VMUsageTracker`, which turns it into CPU fraction and disk rates.
///
/// No VM program installed is reported as `.unavailable(.notApplicable)`, not as an empty list.
/// Demand-driven: sampled only while the Virtual Machines section is visible.
public actor VMMonitor: TelemetryProvider {
    private struct ProviderState {
        var install: VMProviderInstall?
        var detectedAt: MonotonicInstant?
        var records: [VMRecord] = []
        var listedAt: MonotonicInstant?
    }

    /// How often installation is re-checked: an app installed while PulseDeck runs appears within this time.
    private static let redetectInterval: Duration = .seconds(30)

    private let adapters: [any VMProviderAdapter]
    private let environment: VMEnvironment
    private var table = VMHostProcessTable()
    private var tracker = VMUsageTracker()
    private var states: [VMProviderID: ProviderState] = [:]

    public init() {
        adapters = VMProviderRegistry.all
        environment = .live()
    }

    init(adapters: [any VMProviderAdapter], environment: VMEnvironment) {
        self.adapters = adapters
        self.environment = environment
    }

    public func capability() -> TelemetryCapability { .supported }

    public func sample(at instant: MonotonicInstant) async -> MetricState<VirtualMachinesSnapshot> {
        guard let processTable = table.snapshot() else {
            return .unavailable(.transientFailure("sysctl KERN_PROC_ALL failed"))
        }

        // 1. Which providers are installed (cheap file lookups, repeated every 30 s).
        for adapter in adapters {
            var state = states[adapter.id] ?? ProviderState()
            let due = state.detectedAt.map { instant.nanoseconds(since: $0) >= Self.redetectInterval.nanosecondsClamped } ?? true
            if due {
                state.install = adapter.detect(in: environment)
                state.detectedAt = instant
                if state.install == nil { state.records = []; state.listedAt = nil }
                states[adapter.id] = state
            }
        }
        let installed = adapters.filter { states[$0.id]?.install != nil }
        guard !installed.isEmpty else {
            tracker.reset()
            return .unavailable(.notApplicable)
        }

        // 2. List the providers whose listing is due, concurrently.
        let listingDue = installed.filter { adapter in
            guard let listedAt = states[adapter.id]?.listedAt else { return true }
            return instant.nanoseconds(since: listedAt) >= adapter.minimumListInterval.nanosecondsClamped
        }
        let environment = self.environment
        let processes = processTable.processes
        let listings = await withTaskGroup(of: (VMProviderID, [VMRecord]).self) { group in
            for adapter in listingDue {
                group.addTask { (adapter.id, await adapter.list(in: environment, processes: processes)) }
            }
            var collected: [VMProviderID: [VMRecord]] = [:]
            for await (id, records) in group { collected[id] = records }
            return collected
        }
        for (id, records) in listings {
            states[id]?.records = records
            states[id]?.listedAt = instant
        }

        // 3. Build the machines. Reused (throttled) records keep their listed state but lose
        // processes that have exited since.
        var machines: [VirtualMachineSnapshot] = []
        var samples: [String: [VMProcessSample]] = [:]
        var usageByPID: [Int32: Result<ProcessReading.Usage, UnavailableReasonError>] = [:]
        for adapter in installed {
            guard let state = states[adapter.id] else { continue }
            let reused = listings[adapter.id] == nil
            var seen = Set<String>()
            for record in state.records.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                guard seen.insert(record.nativeID).inserted else { continue }
                let id = "\(adapter.id.rawValue):\(record.nativeID)"
                let pids = reused ? record.hostProcessIDs.filter { processTable.identities[$0] != nil } : record.hostProcessIDs
                var machineSamples: [VMProcessSample] = []
                for pid in pids {
                    guard let identity = processTable.identities[pid] else { continue }
                    if usageByPID[pid] == nil { usageByPID[pid] = table.usage(of: pid) }
                    if let usage = usageByPID[pid] { machineSamples.append(VMProcessSample(identity: identity, usage: usage)) }
                }
                samples[id] = machineSamples
                machines.append(VirtualMachineSnapshot(
                    id: id,
                    providerID: adapter.id.rawValue,
                    providerName: adapter.id.displayName,
                    name: record.name,
                    state: record.state,
                    guestOS: record.guestOS,
                    architecture: record.architecture,
                    resources: record.resources,
                    ipAddress: record.ipAddress,
                    startedAt: record.startedAt,
                    hostProcessIDs: pids,
                    details: record.details,
                    capabilities: record.capabilities
                ))
            }
        }

        // 4. Usage.
        let usage = tracker.update(machines: samples, at: instant)
        for index in machines.indices {
            machines[index].usage = usage[machines[index].id] ?? VMUsage.none
        }

        let providers = installed.map { adapter in
            VMProviderStatus(
                id: adapter.id.rawValue,
                name: adapter.id.displayName,
                version: states[adapter.id]?.install?.version,
                machineCount: machines.filter { $0.providerID == adapter.id.rawValue }.count,
                note: states[adapter.id]?.install?.note
            )
        }
        return .available(VirtualMachinesSnapshot(providers: providers, machines: machines))
    }

    public func invalidateBaselines() {
        tracker.reset()
    }
}
#endif
