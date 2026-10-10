import PulseDeckCore
import PulseDeckTelemetry
import SwiftUI

// Labels, symbols, sort keys and "what may be done now" rules for virtual machines.

extension VMState {
    var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .stopped: String(localized: "Stopped")
        case .paused: String(localized: "Paused")
        case .suspended: String(localized: "Suspended")
        case .starting: String(localized: "Starting")
        case .stopping: String(localized: "Stopping")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Each state has its own shape, so the status does not rely on color alone.
    var symbolName: String {
        switch self {
        case .running: "circle.fill"
        case .stopped: "circle"
        case .paused: "pause.circle.fill"
        case .suspended: "moon.zzz.fill"
        case .starting, .stopping: "circle.dotted"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .green
        case .paused, .suspended, .starting, .stopping: .orange
        case .stopped, .unknown: .secondary
        }
    }

    /// Running machines first, then those in between, then the ones that are off.
    var listRank: Int {
        switch self {
        case .running: 0
        case .paused, .suspended, .starting, .stopping: 1
        case .stopped, .unknown: 2
        }
    }
}

extension VirtualMachineSnapshot {
    /// "Linux · arm64", or empty if the provider reports neither.
    var guestDescription: String {
        [guestOS, architecture].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: What can be done now (provider capabilities AND the current state)

    var canStartNow: Bool {
        capabilities.canStart && (state == .stopped || state == .paused || state == .suspended)
    }

    var canStopNow: Bool {
        capabilities.canStop && (state == .running || state == .paused || state == .starting)
    }

    var canRestartNow: Bool {
        capabilities.canRestart && state == .running
    }

    func canPerformNow(_ action: VMAction) -> Bool {
        switch action {
        case .start: canStartNow
        case .stop: canStopNow
        case .restart: canRestartNow
        }
    }

    // MARK: Sort keys. Missing values sort as −1, below every real value.

    var cpusSortValue: Int { resources.cpus ?? -1 }
    var configuredMemorySortValue: Double { resources.memoryBytes.map { Double($0) } ?? -1 }
    var configuredDiskSortValue: Double { resources.diskBytes.map { Double($0) } ?? -1 }
    var hostCPUSortValue: Double { usage.cpu.value ?? -1 }
    var residentMemorySortValue: Double { usage.memoryBytes.value.map { Double($0) } ?? -1 }
    var diskSortValue: Double {
        let values = [usage.diskReadBytesPerSecond.value, usage.diskWriteBytesPerSecond.value].compactMap { $0 }
        return values.isEmpty ? -1 : values.reduce(0, +)
    }
    var stateLabel: String { state.label }
    var ipSortValue: String { ipAddress ?? "" }
}

extension VMControlError {
    /// Short sentence for an alert; `provider` is the display name of the VM's provider.
    func message(provider: String) -> String {
        switch self {
        case .unsupported:
            String(localized: "\(provider) does not offer this action.")
        case .providerUnavailable:
            String(localized: "\(provider) is not available. Is it still installed and able to run?")
        case .failed(let message):
            message
        }
    }
}

extension MetricState where Value == String {
    /// A configured value, or "—" (Not Available for VoiceOver) when the provider does not report it.
    static func text(_ text: String?) -> MetricState<String> {
        guard let text, !text.isEmpty else { return .unavailable(.notApplicable) }
        return .available(text)
    }
}

/// Status symbol with a spoken state ("Running"). Each state has its own shape, so it does not
/// rely on color.
struct VMStatusSymbol: View {
    let state: VMState

    var body: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: 9))
            .foregroundStyle(state.tint)
            .frame(width: 12)
            .accessibilityLabel(Text(verbatim: state.label))
    }
}

extension VMProviderID {
    /// One sentence on how to create a first virtual machine, shown while the provider has none.
    var creationHint: String {
        switch self {
        case .colima: String(localized: "Run “colima start” in Terminal to create one.")
        case .lima: String(localized: "Run “limactl start” in Terminal to create one.")
        case .finch: String(localized: "Run “finch vm init” in Terminal to create one.")
        case .rancherDesktop: String(localized: "Open Rancher Desktop to start its virtual machine.")
        case .orbstack: String(localized: "Open OrbStack to start its virtual machine.")
        case .dockerDesktop: String(localized: "Open Docker Desktop to start its virtual machine.")
        case .tart: String(localized: "Run “tart create” or “tart clone” in Terminal to create one.")
        case .utm: String(localized: "Create one in UTM.")
        case .parallels: String(localized: "Create one in Parallels Desktop.")
        case .vmwareFusion: String(localized: "Create one in VMware Fusion.")
        case .virtualBox: String(localized: "Create one in VirtualBox.")
        case .anka: String(localized: "Run “anka create” in Terminal to create one.")
        case .multipass: String(localized: "Run “multipass launch” in Terminal to create one.")
        case .podman: String(localized: "Run “podman machine init” in Terminal to create one.")
        case .minikube: String(localized: "Run “minikube start” in Terminal to create one.")
        case .vagrant: String(localized: "Run “vagrant up” in a project folder to create one.")
        case .qemu: String(localized: "Start a machine with qemu-system to see it here.")
        }
    }
}
