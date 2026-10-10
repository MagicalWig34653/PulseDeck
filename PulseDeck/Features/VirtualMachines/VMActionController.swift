import Foundation
import Observation
import PulseDeckCore
import PulseDeckTelemetry

/// Runs Start / Stop / Restart and resource changes on virtual machines. Actions take 10–60
/// seconds, so they run in tasks: sampling continues meanwhile, `busyIDs` drives the per-row
/// spinner and a failure becomes an alert. Shared, so a running action keeps its spinner (and
/// reports its failure) when the user leaves and re-enters the section.
@MainActor
@Observable
final class VMActionController {
    static let shared = VMActionController()

    struct Failure: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Machines with an action in flight (`VirtualMachineSnapshot.id`).
    private(set) var busyIDs = Set<String>()
    var failure: Failure?

    private init() {}

    func isBusy(_ machine: VirtualMachineSnapshot) -> Bool {
        busyIDs.contains(machine.id)
    }

    /// Runs `action` on every machine that is not busy; each machine has its own task, so one
    /// slow VM does not hold up the others.
    func perform(_ action: VMAction, on machines: [VirtualMachineSnapshot]) {
        for machine in machines {
            guard busyIDs.insert(machine.id).inserted else { continue }
            Task {
                let result = await VMControl.perform(action, on: machine)
                busyIDs.remove(machine.id)
                if case .failure(let error) = result {
                    failure = Failure(
                        title: Self.title(for: action),
                        message: String(localized: "\(machine.name): \(error.message(provider: machine.providerName))")
                    )
                }
            }
        }
    }

    /// Applies `resources`. For `.stopApplyAndStart` the VM is stopped first and started again by
    /// the provider afterwards; a failure in either step is reported with the VM's resulting state.
    func apply(_ resources: VMResources, to machine: VirtualMachineSnapshot, plan: VMResourceDraft.ApplyPlan) {
        guard plan != .waitForTransition, resources != VMResources(), busyIDs.insert(machine.id).inserted else { return }
        Task {
            let title = String(localized: "The resources could not be changed")
            var message: String?
            switch plan {
            case .waitForTransition:
                break
            case .applyNow:
                if case .failure(let error) = await VMControl.apply(resources, to: machine, restartIfRunning: false) {
                    message = String(localized: "\(machine.name): \(error.message(provider: machine.providerName))")
                }
            case .stopApplyAndStart:
                switch await VMControl.perform(.stop, on: machine) {
                case .failure(let error):
                    message = String(localized: "\(machine.name) could not be stopped, so nothing was changed. \(error.message(provider: machine.providerName))")
                case .success:
                    // `machine` still says "running": that is what tells the provider to start it again.
                    if case .failure(let error) = await VMControl.apply(resources, to: machine, restartIfRunning: true) {
                        message = String(localized: "\(machine.name) was stopped, but the new resources could not be applied or the machine could not be started again. Check its state and start it manually if needed. \(error.message(provider: machine.providerName))")
                    }
                }
            }
            busyIDs.remove(machine.id)
            if let message {
                failure = Failure(title: title, message: message)
            }
        }
    }

    private static func title(for action: VMAction) -> String {
        switch action {
        case .start: String(localized: "The virtual machine could not be started")
        case .stop: String(localized: "The virtual machine could not be stopped")
        case .restart: String(localized: "The virtual machine could not be restarted")
        }
    }
}
