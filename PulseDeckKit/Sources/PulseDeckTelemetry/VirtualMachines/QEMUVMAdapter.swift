#if os(macOS)
import Foundation
import PulseDeckCore

/// Plain QEMU: `qemu-system-*` processes that no known VM manager started. There is no manager to
/// ask, so the process table is the only source (`QEMUVMParsing`, `QEMUCommandLine`). VMs are
/// listed and monitored, never controlled.
public struct QEMUVMAdapter: VMProviderAdapter {
    public init() {}

    public var id: VMProviderID { .qemu }

    /// Directories whose `qemu-system-*` binaries show that QEMU is installed (Homebrew on Apple
    /// silicon and Intel, MacPorts).
    private static let binaryDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    private static let cellars = ["/opt/homebrew/Cellar/qemu", "/usr/local/Cellar/qemu"]

    public func detect(in environment: VMEnvironment) -> VMProviderInstall? {
        let fileManager = FileManager.default
        let installed = Self.binaryDirectories.contains { directory in
            ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? []).contains { $0.hasPrefix("qemu-system-") }
        }
        guard installed else { return nil }
        let versions = Self.cellars.flatMap { (try? fileManager.contentsOfDirectory(atPath: $0)) ?? [] }
        return VMProviderInstall(version: PodmanVMParsing.highestVersion(of: versions), note: "Read-only: plain QEMU processes have no management interface.")
    }

    public func list(in environment: VMEnvironment, processes: [VMHostProcess]) async -> [VMRecord] {
        QEMUVMParsing.records(processes: processes)
    }

    public func perform(_ action: VMAction, on machine: VirtualMachineSnapshot, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        .failure(.unsupported)
    }

    public func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool, in environment: VMEnvironment) async -> Result<Void, VMControlError> {
        .failure(.unsupported)
    }
}
#endif
