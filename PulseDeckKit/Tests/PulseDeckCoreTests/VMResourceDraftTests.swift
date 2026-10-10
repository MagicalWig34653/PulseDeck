import Foundation
import Testing
@testable import PulseDeckCore

@Suite struct VMResourceDraftTests {
    private let gib = VMResourceDraft.bytesPerGiB

    private let editable = VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: true)

    private func makeDraft(cpus: Int? = 2, memoryGiB: UInt64? = 4, diskGiB: UInt64? = 60, capabilities: VMCapabilities? = nil,
                       hostCPUs: Int = 10, hostMemoryGiB: UInt64 = 32) -> VMResourceDraft {
        VMResourceDraft(
            original: VMResources(cpus: cpus, memoryBytes: memoryGiB.map { $0 * gib }, diskBytes: diskGiB.map { $0 * gib }),
            capabilities: capabilities ?? editable,
            hostCPUs: hostCPUs,
            hostMemoryBytes: hostMemoryGiB * gib
        )
    }

    @Test func startsUnchanged() {
        let draft = makeDraft()
        #expect(draft.cpus == 2)
        #expect(draft.memoryGiB == 4)
        #expect(draft.diskGiB == 60)
        #expect(draft.changes == VMResources())
        #expect(!draft.hasChanges)
        #expect(!draft.canApply)
    }

    @Test func onlyChangedValuesAreSent() {
        var draft = makeDraft()
        draft.cpus = 4
        #expect(draft.changes == VMResources(cpus: 4, memoryBytes: nil, diskBytes: nil))
        draft.memoryGiB = 8
        draft.diskGiB = 100
        #expect(draft.changes == VMResources(cpus: 4, memoryBytes: 8 * gib, diskBytes: 100 * gib))
        #expect(draft.canApply)
    }

    @Test func valuesThatAreNotWholeGiBAreNotSentUnlessEdited() {
        // 1536 MiB rounds to 2 GiB in the editor; leaving it alone must not turn it into 2 GiB.
        let draft = VMResourceDraft(
            original: VMResources(cpus: 2, memoryBytes: 1_536 * 1_048_576, diskBytes: nil),
            capabilities: editable, hostCPUs: 8, hostMemoryBytes: 16 * gib
        )
        #expect(draft.memoryGiB == 2)
        #expect(draft.changes.memoryBytes == nil)
    }

    @Test func uneditableValuesAreNeverSent() {
        var caps = editable
        caps.canEditMemory = false
        var draft = makeDraft(capabilities: caps)
        draft.memoryGiB = 16
        draft.cpus = 3
        #expect(!draft.canEditMemory)
        #expect(draft.changes == VMResources(cpus: 3, memoryBytes: nil, diskBytes: nil))
    }

    @Test func unreportedValueCannotBeEdited() {
        let draft = makeDraft(cpus: nil)
        #expect(!draft.canEditCPUs)
        #expect(draft.canEditMemory)
        #expect(draft.changes.cpus == nil)
    }

    @Test func readOnlyProviderEditsNothing() {
        var draft = makeDraft(capabilities: .readOnly)
        draft.cpus = 6
        draft.memoryGiB = 12
        #expect(!draft.canEditAnything)
        #expect(draft.changes == VMResources())
        #expect(!draft.canApply)
    }

    @Test func rangesFollowTheHost() {
        let draft = makeDraft(hostCPUs: 10, hostMemoryGiB: 32)
        #expect(draft.cpuRange == 1...10)
        #expect(draft.memoryRange == 1...31)
        #expect(draft.diskRange.lowerBound == 60)
    }

    @Test func rangesIncludeValuesAboveTheHostLimits() {
        let draft = makeDraft(cpus: 16, memoryGiB: 8, hostCPUs: 8, hostMemoryGiB: 8)
        #expect(draft.cpuRange == 1...16)
        #expect(draft.memoryRange == 1...8)
        #expect(draft.isValid)
    }

    @Test func tinyHostStillHasValidRange() {
        let draft = makeDraft(memoryGiB: nil, hostCPUs: 0, hostMemoryGiB: 1)
        #expect(draft.cpuRange == 1...2)
        #expect(draft.memoryRange == 1...1)
    }

    @Test func diskCanOnlyGrow() {
        var draft = makeDraft()
        draft.diskGiB = 50
        #expect(draft.diskIssue == .cannotShrink(minimumGiB: 60))
        #expect(!draft.isValid)
        #expect(!draft.canApply)
        draft.diskGiB = 61
        #expect(draft.diskIssue == nil)
        #expect(draft.canApply)
    }

    @Test func diskMayShrinkWhenProviderAllowsIt() {
        var caps = editable
        caps.diskCanOnlyGrow = false
        var draft = makeDraft(capabilities: caps)
        draft.diskGiB = 20
        #expect(draft.diskIssue == nil)
        #expect(draft.changes.diskBytes == 20 * gib)
    }

    @Test func diskIsRoundedUpSoItNeverStartsBelowItsSize() {
        // 100 GB (decimal) is 93.13 GiB.
        let draft = VMResourceDraft(
            original: VMResources(cpus: 1, memoryBytes: gib, diskBytes: 100_000_000_000),
            capabilities: editable, hostCPUs: 4, hostMemoryBytes: 8 * gib
        )
        #expect(draft.diskGiB == 94)
        #expect(draft.diskRange.lowerBound == 94)
        #expect(draft.diskIssue == nil)
        #expect(draft.changes.diskBytes == nil)
    }

    @Test func memoryCautionAboveThreeQuartersOfTheHost() {
        var draft = makeDraft(hostMemoryGiB: 16)
        draft.memoryGiB = 12
        #expect(!draft.exceedsMemoryCaution)
        draft.memoryGiB = 13
        #expect(draft.exceedsMemoryCaution)
        #expect(draft.memoryFractionOfHost > 0.75)
    }

    @Test func outOfRangeValuesAreInvalid() {
        var draft = makeDraft()
        draft.cpus = 11
        #expect(!draft.isValid)
        draft.cpus = 4
        draft.memoryGiB = 32
        #expect(!draft.isValid)
    }

    @Test func plansDependOnTheProviderAndTheState() {
        let draft = makeDraft()
        #expect(draft.plan(for: .stopped) == .applyNow)
        #expect(draft.plan(for: .running) == .stopApplyAndStart)
        #expect(draft.plan(for: .paused) == .stopApplyAndStart)
        #expect(draft.plan(for: .starting) == .waitForTransition)
        #expect(draft.plan(for: .stopping) == .waitForTransition)

        var live = editable
        live.editRequiresStopped = false
        let liveDraft = makeDraft(capabilities: live)
        #expect(liveDraft.plan(for: .running) == .applyNow)
    }
}
