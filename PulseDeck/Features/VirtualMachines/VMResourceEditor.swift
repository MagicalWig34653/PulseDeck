import Foundation
import PulseDeckCore
import SwiftUI

/// Sheet for changing the CPUs, memory and disk of one virtual machine. What can be edited, the
/// allowed ranges and what is sent (only changed values) are decided by `VMResourceDraft`; the
/// provider's own rules arrive through `VMCapabilities`. Providers that only apply changes to a
/// stopped machine get an explicit "Stop, Apply and Start".
struct VMResourceEditor: View {
    /// The live machine: its state keeps updating while the sheet is open.
    let machine: VirtualMachineSnapshot
    let onApply: (VMResources, VMResourceDraft.ApplyPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: VMResourceDraft

    init(machine: VirtualMachineSnapshot, onApply: @escaping (VMResources, VMResourceDraft.ApplyPlan) -> Void) {
        self.machine = machine
        self.onApply = onApply
        _draft = State(initialValue: VMResourceDraft(
            original: machine.resources,
            capabilities: machine.capabilities,
            hostCPUs: ProcessInfo.processInfo.activeProcessorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory
        ))
    }

    var body: some View {
        let plan = draft.plan(for: machine.state)
        VStack(spacing: 0) {
            Form {
                Section {
                    planNotice(plan)
                } header: {
                    Text(verbatim: machine.name)
                }
                cpuSection
                memorySection
                diskSection
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 12) {
                Text(verbatim: changeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    onApply(draft.changes, plan)
                    dismiss()
                } label: {
                    if plan == .stopApplyAndStart {
                        Text("Stop, Apply and Start")
                    } else {
                        Text("Apply")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canApply || plan == .waitForTransition)
            }
            .padding(12)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 440, idealHeight: 560)
    }

    // MARK: - Notices

    @ViewBuilder
    private func planNotice(_ plan: VMResourceDraft.ApplyPlan) -> some View {
        switch plan {
        case .stopApplyAndStart:
            Label {
                Text("\(machine.providerName) applies these changes only to a stopped machine. PulseDeck will stop “\(machine.name)”, apply the changes and start it again. Unsaved work inside the machine can be lost.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .waitForTransition:
            Label {
                Text("“\(machine.name)” is \(machine.state.label.lowercased()). Try again when it has finished.")
            } icon: {
                Image(systemName: "hourglass")
            }
        case .applyNow:
            Text("Changes are applied to “\(machine.name)” (\(machine.providerName)) and take effect the next time it starts.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "CPUs 2 → 4 · Memory 4 → 8 GiB", or why nothing can be applied yet.
    private var changeSummary: String {
        let changes = draft.changes
        var parts: [String] = []
        if changes.cpus != nil, let initial = draft.initialCPUs {
            parts.append(String(localized: "CPUs \(initial) → \(draft.cpus)"))
        }
        if changes.memoryBytes != nil, let initial = draft.initialMemoryGiB {
            parts.append(String(localized: "Memory \(initial) → \(draft.memoryGiB) GiB"))
        }
        if changes.diskBytes != nil, let initial = draft.initialDiskGiB {
            parts.append(String(localized: "Disk \(initial) → \(draft.diskGiB) GiB"))
        }
        if parts.isEmpty {
            return draft.canEditAnything ? String(localized: "No changes yet.") : String(localized: "Nothing can be changed for this machine.")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - CPUs

    private var cpuSection: some View {
        Section {
            LabeledContent("CPUs") {
                if draft.canEditCPUs {
                    HStack(spacing: 8) {
                        Text(verbatim: String(draft.cpus))
                            .monospacedDigit()
                        Stepper("CPUs", value: $draft.cpus, in: draft.cpuRange)
                            .labelsHidden()
                    }
                } else {
                    Text(verbatim: machine.resources.cpus.map { String($0) } ?? AppState.placeholder)
                        .foregroundStyle(.secondary)
                }
            }
            if draft.canEditCPUs {
                hint(String(localized: "This Mac has \(draft.hostCPUs) logical processors. A machine can be given at most that many."))
            } else {
                hint(notEditableReason(isAllowed: machine.capabilities.canEditCPUs, isReported: machine.resources.cpus != nil))
            }
        } header: {
            Text("Processors")
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            LabeledContent("Memory") {
                if draft.canEditMemory {
                    Text(verbatim: String(localized: "\(draft.memoryGiB) GiB"))
                        .monospacedDigit()
                } else {
                    Text(verbatim: machine.resources.memoryBytes.map(Format.memory) ?? AppState.placeholder)
                        .foregroundStyle(.secondary)
                }
            }
            if draft.canEditMemory {
                let range = draft.memoryRange
                if range.lowerBound < range.upperBound {
                    Slider(value: memoryBinding, in: Double(range.lowerBound)...Double(range.upperBound), step: 1) {
                        Text("Memory")
                    }
                    .labelsHidden()
                    .accessibilityValue(Text(verbatim: String(localized: "\(draft.memoryGiB) GiB")))
                }
                hint(String(localized: "This Mac has \(Format.memory(draft.hostMemoryBytes)) of memory."))
                if draft.exceedsMemoryCaution {
                    Label {
                        Text("That is \(Format.percent(draft.memoryFractionOfHost)) of this Mac’s memory. macOS and your apps may become slow while the machine runs.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                hint(notEditableReason(isAllowed: machine.capabilities.canEditMemory, isReported: machine.resources.memoryBytes != nil))
            }
        } header: {
            Text("Memory")
        }
    }

    private var memoryBinding: Binding<Double> {
        Binding {
            Double(draft.memoryGiB)
        } set: { newValue in
            let range = draft.memoryRange
            draft.memoryGiB = min(max(Int(newValue.rounded()), range.lowerBound), range.upperBound)
        }
    }

    // MARK: - Disk

    private var diskSection: some View {
        Section {
            LabeledContent("Disk") {
                if draft.canEditDisk {
                    HStack(spacing: 8) {
                        TextField("Disk size in GiB", value: $draft.diskGiB, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 80)
                        Text("GiB")
                        Stepper("Disk size", value: $draft.diskGiB, in: draft.diskRange)
                            .labelsHidden()
                    }
                } else {
                    Text(verbatim: machine.resources.diskBytes.map(Format.memory) ?? AppState.placeholder)
                        .foregroundStyle(.secondary)
                }
            }
            if draft.canEditDisk {
                switch draft.diskIssue {
                case .cannotShrink(let minimum)?:
                    Label {
                        Text("A virtual disk can only be enlarged. The minimum is \(minimum) GiB.")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                case .outOfRange?:
                    Label {
                        Text("Enter a size between \(draft.diskRange.lowerBound) and \(draft.diskRange.upperBound) GiB.")
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                case nil:
                    hint(machine.capabilities.diskCanOnlyGrow
                        ? String(localized: "The disk can only be enlarged, never made smaller. The guest may need to extend its partition or file system to use the new space.")
                        : String(localized: "The guest may need to adjust its partition or file system after the size changes."))
                }
            } else {
                hint(notEditableReason(isAllowed: machine.capabilities.canEditDisk, isReported: machine.resources.diskBytes != nil))
            }
        } header: {
            Text("Disk")
        }
    }

    // MARK: - Helpers

    private func hint(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func notEditableReason(isAllowed: Bool, isReported: Bool) -> String {
        if !isAllowed {
            return String(localized: "\(machine.providerName) offers no way to change this from PulseDeck.")
        }
        if !isReported {
            return String(localized: "\(machine.providerName) does not report the current value, so it cannot be changed safely.")
        }
        return ""
    }
}
