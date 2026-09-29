#if os(macOS)
import Darwin
import Foundation
import IOKit
import PulseDeckCore

/// Live CPU cluster frequencies (Apple silicon).
///
/// macOS has no public API for the current CPU frequency. The product owner approved the private
/// IOReport library for this one purpose, labelled in the UI, with fallback to *Not Available*
/// (TECHNICAL_LIMITATIONS.md L‑11):
///
/// - `libIOReport.dylib` is opened with `dlopen` (never linked), so a missing or changed library
///   only disables the feature.
/// - Channel group "CPU Stats", subgroup "CPU Complex Performance States": per-cluster residency
///   in each performance state since the previous sample.
/// - State frequencies come from the device tree (`IODeviceTree:/arm-io/pmgr`, properties
///   `voltage-states1-sram` for E-clusters and `voltage-states5-sram` for P-clusters), parsed and
///   validated by `CPUFrequencyCalculator`.
///
/// Demand-driven: sampled only while the CPU page is visible.
public actor CPUFrequencyMonitor: TelemetryProvider {
    private let library: IOReportLibrary?
    private let subscription: OpaquePointer?
    private let subscribedChannels: CFMutableDictionary?
    private let tables: [CoreType: [Double]]
    private var previous: CFDictionary?

    private static let group = "CPU Stats"
    private static let clusterSubgroup = "CPU Complex Performance States"
    private static let channelsKey = "IOReportChannels"

    public init() {
        tables = Self.readFrequencyTables()
        guard let library = IOReportLibrary() else {
            self.library = nil
            subscription = nil
            subscribedChannels = nil
            return
        }
        self.library = library
        var subscribed: Unmanaged<CFMutableDictionary>?
        if let channels = library.copyChannelsInGroup(Self.group as CFString, Self.clusterSubgroup as CFString, 0, 0, 0)?.takeRetainedValue(),
           let created = library.createSubscription(nil, channels, &subscribed, 0, nil) {
            subscription = created
            subscribedChannels = subscribed?.takeRetainedValue() ?? channels
        } else {
            subscription = nil
            subscribedChannels = nil
        }
    }

    public func capability() -> TelemetryCapability {
        if library == nil { return .unsupported(.noPublicAPI) }
        if subscription == nil || tables.isEmpty { return .unsupported(.unsupportedHardware) }
        return .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<CPUFrequencySnapshot> {
        guard let library else { return .unavailable(.noPublicAPI) }
        guard let subscription, let subscribedChannels, !tables.isEmpty else { return .unavailable(.unsupportedHardware) }
        guard let current = library.createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue() else {
            return .unavailable(.transientFailure("IOReportCreateSamples failed"))
        }
        let baseline = previous
        previous = current
        guard let baseline else { return .unavailable(.awaitingBaseline) }
        guard let delta = library.createSamplesDelta(baseline, current, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)[Self.channelsKey] as? [NSDictionary]
        else {
            return .unavailable(.transientFailure("IOReportCreateSamplesDelta failed"))
        }

        var clusters: [ClusterFrequency] = []
        for channel in channels {
            let item = channel as CFDictionary
            guard let subgroup = library.channelGetSubGroup(item).map({ $0.takeUnretainedValue() as String }),
                  subgroup == Self.clusterSubgroup,
                  let name = library.channelGetChannelName(item).map({ $0.takeUnretainedValue() as String }),
                  let coreType = CPUFrequencyCalculator.coreType(ofChannel: name),
                  let table = tables[coreType]
            else { continue }
            let count = library.stateGetCount(item)
            guard count > 0 else { continue }
            var states: [(name: String, residency: Int64)] = []
            for index in 0..<count {
                let stateName = library.stateGetNameForIndex(item, index).map { $0.takeUnretainedValue() as String } ?? ""
                states.append((stateName, library.stateGetResidency(item, index)))
            }
            if let cluster = CPUFrequencyCalculator.cluster(id: name, coreType: coreType, states: states, table: table) {
                clusters.append(cluster)
            }
        }
        guard !clusters.isEmpty else { return .unavailable(.unsupportedHardware) }
        // E-clusters first, then P-clusters, each in channel order.
        clusters.sort { ($0.coreType == .efficiency ? 0 : 1, $0.id) < ($1.coreType == .efficiency ? 0 : 1, $1.id) }
        return .available(CPUFrequencySnapshot(clusters: clusters))
    }

    public func invalidateBaselines() {
        previous = nil
    }

    /// State frequency tables per core type from the power manager's device-tree node.
    private static func readFrequencyTables() -> [CoreType: [Double]] {
        let pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard pmgr != 0 else { return [:] }
        defer { IOObjectRelease(pmgr) }
        func table(_ keys: [String]) -> [Double]? {
            for key in keys {
                if let data = IORegistryEntryCreateCFProperty(pmgr, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
                   let table = CPUFrequencyCalculator.frequencyTable(fromVoltageStates: [UInt8](data)) {
                    return table
                }
            }
            return nil
        }
        var tables: [CoreType: [Double]] = [:]
        tables[.efficiency] = table(["voltage-states1-sram", "voltage-states1"])
        tables[.performance] = table(["voltage-states5-sram", "voltage-states5"])
        return tables
    }
}

/// Function pointers into the private `libIOReport.dylib`, resolved at run time. Signatures as
/// used by open-source monitors of Apple silicon; ownership follows the CF Create/Copy/Get rule.
struct IOReportLibrary {
    typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, UnsafeRawPointer?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, UnsafeRawPointer?) -> Unmanaged<CFDictionary>?
    typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias StateGetCount = @convention(c) (CFDictionary) -> Int32
    typealias StateGetName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    typealias StateGetResidency = @convention(c) (CFDictionary, Int32) -> Int64

    static let path = "/usr/lib/libIOReport.dylib"

    let copyChannelsInGroup: CopyChannelsInGroup
    let createSubscription: CreateSubscription
    let createSamples: CreateSamples
    let createSamplesDelta: CreateSamplesDelta
    let channelGetSubGroup: ChannelString
    let channelGetChannelName: ChannelString
    let stateGetCount: StateGetCount
    let stateGetNameForIndex: StateGetName
    let stateGetResidency: StateGetResidency

    init?() {
        guard let handle = dlopen(Self.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let copyChannelsInGroup = symbol("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self),
              let createSubscription = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
              let createSamplesDelta = symbol("IOReportCreateSamplesDelta", as: CreateSamplesDelta.self),
              let channelGetSubGroup = symbol("IOReportChannelGetSubGroup", as: ChannelString.self),
              let channelGetChannelName = symbol("IOReportChannelGetChannelName", as: ChannelString.self),
              let stateGetCount = symbol("IOReportStateGetCount", as: StateGetCount.self),
              let stateGetNameForIndex = symbol("IOReportStateGetNameForIndex", as: StateGetName.self),
              let stateGetResidency = symbol("IOReportStateGetResidency", as: StateGetResidency.self)
        else { return nil }
        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelGetSubGroup = channelGetSubGroup
        self.channelGetChannelName = channelGetChannelName
        self.stateGetCount = stateGetCount
        self.stateGetNameForIndex = stateGetNameForIndex
        self.stateGetResidency = stateGetResidency
    }
}
#endif
