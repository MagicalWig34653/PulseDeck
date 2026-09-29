#if os(macOS)
import Darwin
import PulseDeckCore

/// System memory from VM statistics (SPEC §14). See `MemoryCalculator` for the formulas.
public actor MemoryMonitor: TelemetryProvider {
    private let host: host_t
    private let physicalTotal: UInt64?
    private let pageSize: UInt64?

    public init() {
        let host = mach_host_self()
        self.host = host
        physicalTotal = Sysctl.integer("hw.memsize", as: UInt64.self)
        var size: vm_size_t = 0
        // VM statistics count pages of the kernel's page size (16 KiB on Apple silicon).
        pageSize = host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : nil
    }

    public func capability() -> TelemetryCapability {
        physicalTotal != nil && pageSize != nil ? .supported : .unsupported(.transientFailure("hw.memsize/page size unavailable"))
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<MemorySnapshot> {
        guard let physicalTotal, let pageSize, let pages = readPages() else {
            return .unavailable(.transientFailure("host_statistics64 failed"))
        }
        return .available(MemoryCalculator.snapshot(
            physicalTotal: physicalTotal,
            pageSize: pageSize,
            pages: pages,
            swap: readSwap(),
            pressure: readPressure()
        ))
    }

    public func invalidateBaselines() {
        // Memory values are instantaneous; there are no baselines.
    }

    private func readPages() -> VMPageCounts? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = self.host
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            free: UInt64(stats.free_count),
            active: UInt64(stats.active_count),
            inactive: UInt64(stats.inactive_count),
            wired: UInt64(stats.wire_count),
            speculative: UInt64(stats.speculative_count),
            purgeable: UInt64(stats.purgeable_count),
            compressor: UInt64(stats.compressor_page_count),
            internalPages: UInt64(stats.internal_page_count),
            externalPages: UInt64(stats.external_page_count),
            uncompressedInCompressor: UInt64(stats.total_uncompressed_pages_in_compressor)
        )
    }

    private func readSwap() -> MetricState<SwapUsage> {
        guard let usage = Sysctl.structure("vm.swapusage", initial: xsw_usage()) else {
            return .unavailable(.transientFailure("vm.swapusage failed"))
        }
        return .available(SwapUsage(used: usage.xsu_used, total: usage.xsu_total))
    }

    /// Undocumented but unprivileged sysctl returning the current dispatch pressure level.
    /// Approved for use; see TECHNICAL_LIMITATIONS.md L‑8. Falls back to `Not Available`.
    private func readPressure() -> MetricState<MemoryPressure> {
        guard let level = Sysctl.integer("kern.memorystatus_vm_pressure_level", as: UInt32.self),
              let pressure = MemoryPressure(dispatchLevel: level)
        else {
            return .unavailable(.transientFailure("kern.memorystatus_vm_pressure_level unavailable"))
        }
        return .available(pressure)
    }
}
#endif
