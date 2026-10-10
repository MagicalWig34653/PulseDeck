#if os(macOS)
import Foundation
import PulseDeckCore

public enum VMControlError: Error, Hashable, Sendable {
    /// The provider offers no way to do this.
    case unsupported
    /// The provider's command-line tool or app is gone.
    case providerUnavailable
    case failed(String)
}

extension VMEnvironment {
    /// The real machine: the current user's home and the real command runner.
    public static func live() -> VMEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return VMEnvironment(homeDirectory: home, runner: VMCommandRunner(homeDirectory: home))
    }
}

extension VMCommandRunning {
    /// Runs a plan; plans with extra environment variables need the concrete runner (the protocol
    /// has no place for them), other runners ignore the variables.
    func run(_ plan: VMCommandPlan) async -> VMCommandResult? {
        if let concrete = self as? VMCommandRunner { return await concrete.run(plan: plan) }
        return await run(tool: plan.tool, arguments: plan.arguments, timeout: plan.timeout)
    }

    /// Runs plans one after the other and stops at the first failure.
    func run(sequence plans: [VMCommandPlan]) async -> Result<Void, VMControlError> {
        for plan in plans {
            guard let result = await run(plan) else { return .failure(.providerUnavailable) }
            guard result.succeeded else { return .failure(.failed(VMCommandFailure.message(for: plan, result: result))) }
        }
        return .success(())
    }
}

enum VMCommandFailure {
    /// A one-line reason for the UI: the last meaningful line of the tool's error output, else its output, else the exit status.
    static func message(for plan: VMCommandPlan, result: VMCommandResult) -> String {
        let source = result.standardError.isEmpty ? result.standardOutput : result.standardError
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let detail = lines.last.map { String($0.prefix(300)) }
        return detail.map { "\(plan.title): \($0)" } ?? "\(plan.title) exited with status \(result.exitStatus)."
    }
}

/// Starts, stops, restarts and reconfigures VMs on a user's click: looks up the machine's
/// provider and lets its adapter run the vendor's own tool once.
public enum VMControl {
    public static func perform(_ action: VMAction, on machine: VirtualMachineSnapshot) async -> Result<Void, VMControlError> {
        guard let adapter = adapter(for: machine) else { return .failure(.unsupported) }
        let allowed: Bool = switch action {
        case .start: machine.capabilities.canStart
        case .stop: machine.capabilities.canStop
        case .restart: machine.capabilities.canRestart
        }
        guard allowed else { return .failure(.unsupported) }
        return await adapter.perform(action, on: machine, in: .live())
    }

    /// Applies new resources. For providers that need a stopped VM the UI stops it first and
    /// starts it again afterwards (`restartIfRunning`).
    public static func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, restartIfRunning: Bool) async -> Result<Void, VMControlError> {
        guard let adapter = adapter(for: machine), machine.capabilities.canEditAnything else { return .failure(.unsupported) }
        return await adapter.apply(resources, to: machine, restartIfRunning: restartIfRunning, in: .live())
    }

    private static func adapter(for machine: VirtualMachineSnapshot) -> (any VMProviderAdapter)? {
        VMProviderRegistry.all.first { $0.id.rawValue == machine.providerID }
    }
}
#endif
