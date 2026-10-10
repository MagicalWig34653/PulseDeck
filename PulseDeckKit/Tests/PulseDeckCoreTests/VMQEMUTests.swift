import Foundation
import Testing
@testable import PulseDeckCore

@Suite("QEMU command line")
struct VMQEMUCommandLineTests {
    private let gib: UInt64 = 1_073_741_824
    private let mib: UInt64 = 1_048_576

    @Test func memorySyntax() {
        #expect(QEMUCommandLine(arguments: ["-m", "4G"]).memoryBytes == 4 * gib)
        #expect(QEMUCommandLine(arguments: ["-m", "4096"]).memoryBytes == 4096 * mib)
        #expect(QEMUCommandLine(arguments: ["-m", "size=4096"]).memoryBytes == 4096 * mib)
        #expect(QEMUCommandLine(arguments: ["-m", "size=2G,slots=2,maxmem=8G"]).memoryBytes == 2 * gib)
        #expect(QEMUCommandLine(arguments: ["-m", "1G,slots=3,maxmem=4G"]).memoryBytes == gib)
        #expect(QEMUCommandLine(arguments: ["-m", "512M"]).memoryBytes == 512 * mib)
        #expect(QEMUCommandLine(arguments: ["-m", "1.5G"]).memoryBytes == gib + 512 * mib)
        #expect(QEMUCommandLine(arguments: ["--m", "2g"]).memoryBytes == 2 * gib)
        #expect(QEMUCommandLine(arguments: ["-m", "lots"]).memoryBytes == nil)
        #expect(QEMUCommandLine(arguments: ["-m", "0"]).memoryBytes == nil)
        #expect(QEMUCommandLine(arguments: []).memoryBytes == nil, "QEMU's default is not assumed")
    }

    @Test func smpSyntax() {
        #expect(QEMUCommandLine(arguments: ["-smp", "4"]).cpuCount == 4)
        #expect(QEMUCommandLine(arguments: ["-smp", "4,sockets=1,cores=4"]).cpuCount == 4)
        #expect(QEMUCommandLine(arguments: ["-smp", "cpus=4"]).cpuCount == 4)
        #expect(QEMUCommandLine(arguments: ["-smp", "cpus=2,maxcpus=8"]).cpuCount == 2)
        #expect(QEMUCommandLine(arguments: ["-smp", "maxcpus=6"]).cpuCount == 6)
        #expect(QEMUCommandLine(arguments: ["-smp", "sockets=2,cores=2,threads=2"]).cpuCount == 8)
        #expect(QEMUCommandLine(arguments: ["-smp", "cpus=0"]).cpuCount == nil)
        #expect(QEMUCommandLine(arguments: ["-smp", "x"]).cpuCount == nil)
        #expect(QEMUCommandLine(arguments: []).cpuCount == nil)
    }

    @Test func nameSyntax() {
        #expect(QEMUCommandLine(arguments: ["-name", "devbox"]).guestName == "devbox")
        #expect(QEMUCommandLine(arguments: ["-name", "guest=devbox,process=qemu-devbox"]).guestName == "devbox")
        #expect(QEMUCommandLine(arguments: ["-name", "devbox,debug-threads=on"]).guestName == "devbox")
        #expect(QEMUCommandLine(arguments: ["-name", "process=only"]).guestName == nil)
        #expect(QEMUCommandLine(arguments: ["--name", "dash"]).guestName == "dash")
    }

    @Test func drives() {
        let line = QEMUCommandLine(arguments: [
            "-drive", "file=/vm/root.qcow2,if=virtio,format=qcow2",
            "-drive", "file=/iso/install.iso,media=cdrom",
            "-drive", "if=pflash,format=raw,file=/fw/edk2.fd,readonly=on",
            "-hda", "/vm/old.img",
            "-cdrom", "/iso/other.iso",
            "-blockdev", "driver=qcow2,file.driver=file,file.filename=/vm/data.qcow2,node-name=d0",
            "-drive", "file=/odd,,name.img",
        ])
        #expect(line.diskImages == ["/vm/root.qcow2", "/vm/old.img", "/vm/data.qcow2", "/odd,name.img"])
    }

    @Test func machineAcceleratorAndUUID() {
        let line = QEMUCommandLine(arguments: ["-machine", "virt,accel=hvf,highmem=on", "-uuid", "11111111-2222-3333-4444-555555555555"])
        #expect(line.machineType == "virt")
        #expect(line.accelerator == "hvf")
        #expect(line.uuid == "11111111-2222-3333-4444-555555555555")
        #expect(QEMUCommandLine(arguments: ["-M", "q35", "-accel", "tcg"]).machineType == "q35")
        #expect(QEMUCommandLine(arguments: ["-M", "q35", "-accel", "tcg"]).accelerator == "tcg")
        #expect(QEMUCommandLine(arguments: ["-machine", "type=pc,accel=kvm"]).machineType == "pc")
    }

    @Test func realisticLine() {
        let line = QEMUCommandLine(arguments: [
            "-machine", "virt,accel=hvf", "-cpu", "host", "-name", "guest=alpine,process=alpine",
            "-m", "2G", "-smp", "cpus=2,sockets=1,cores=2,threads=1",
            "-drive", "file=/Users/lino/vms/alpine.qcow2,if=virtio,format=qcow2",
            "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0,hostfwd=tcp::2222-:22",
            "-nographic", "-serial", "mon:stdio",
        ])
        #expect(line.guestName == "alpine")
        #expect(line.memoryBytes == 2 * gib)
        #expect(line.cpuCount == 2)
        #expect(line.diskImages == ["/Users/lino/vms/alpine.qcow2"])
        #expect(line.machineType == "virt")
        #expect(line.accelerator == "hvf")
    }

    @Test func tolerantOfTrailingOptionsAndFlags() {
        #expect(QEMUCommandLine(arguments: ["-nographic", "-m"]).memoryBytes == nil)
        #expect(QEMUCommandLine(arguments: ["-nographic", "-m", "1G"]).memoryBytes == gib)
        #expect(QEMUCommandLine(arguments: ["-", "--", "-m", "1G"]).memoryBytes == gib)
    }

    @Test func architectureFromExecutableName() {
        #expect(QEMUCommandLine.architecture(forExecutableName: "qemu-system-aarch64") == "arm64")
        #expect(QEMUCommandLine.architecture(forExecutableName: "qemu-system-x86_64") == "x86_64")
        #expect(QEMUCommandLine.architecture(forExecutableName: "qemu-system-riscv64") == "riscv64")
        #expect(QEMUCommandLine.architecture(forExecutableName: "qemu-img") == nil)
        #expect(QEMUCommandLine.architecture(forExecutableName: "qemu-system-") == nil)
    }
}

@Suite("QEMU process detection")
struct VMQEMUDetectionTests {
    private func qemu(pid: Int32, _ arguments: [String], name: String = "qemu-system-aarch64", path: String? = "/opt/homebrew/bin/qemu-system-aarch64") -> VMHostProcess {
        VMHostProcess(pid: pid, parentPID: 1, name: name, executablePath: path, arguments: arguments)
    }

    @Test func listsBareProcesses() throws {
        let process = qemu(pid: 300, ["-name", "alpine", "-m", "2G", "-smp", "2", "-drive", "file=/Users/lino/vms/alpine.qcow2,if=virtio", "-machine", "virt,accel=hvf"])
        let record = try #require(QEMUVMParsing.records(processes: [process]).first)
        #expect(record.nativeID == "name-alpine")
        #expect(record.name == "alpine")
        #expect(record.state == .running)
        #expect(record.architecture == "arm64")
        #expect(record.resources == VMResources(cpus: 2, memoryBytes: 2 * 1_073_741_824, diskBytes: nil))
        #expect(record.hostProcessIDs == [300])
        #expect(record.capabilities == .readOnly)
        #expect(record.details.contains { $0.label == "Disk image" && $0.value == "/Users/lino/vms/alpine.qcow2" })
        #expect(record.details.contains { $0.label == "Accelerator" && $0.value == "hvf" })
    }

    @Test func skipsManagedProcesses() {
        let processes = [
            qemu(pid: 1, ["-name", "lima-default", "-drive", "file=/Users/lino/.lima/default/diffdisk"]),
            qemu(pid: 2, ["-name", "colima", "-m", "2048"]),
            qemu(pid: 3, ["-drive", "file=/Users/lino/.colima/_lima/colima/basedisk"]),
            qemu(pid: 4, ["-name", "vm"], path: "/Applications/UTM.app/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/qemu-system-aarch64"),
            qemu(pid: 5, ["-drive", "file=/var/root/Library/Application Support/multipassd/qemu/vault/instances/a/x.img"]),
            qemu(pid: 6, ["-drive", "file=/Users/lino/.local/share/containers/podman/machine/qemu/podman-machine-default_fedora.qcow2"]),
            qemu(pid: 7, ["-drive", "file=/Users/lino/.minikube/machines/minikube/disk.qcow2"]),
            qemu(pid: 8, ["-drive", "file=/Users/lino/code/web/.vagrant/machines/default/qemu/x.qcow2"]),
            qemu(pid: 9, ["-name", "lima-x"]),
        ]
        #expect(QEMUVMParsing.records(processes: processes).isEmpty)
        #expect(QEMUVMParsing.managerName(of: processes[0]) == "Lima")
        #expect(QEMUVMParsing.managerName(of: processes[1]) == "Colima")
        #expect(QEMUVMParsing.managerName(of: processes[3]) == "UTM")
        #expect(QEMUVMParsing.managerName(of: processes[4]) == "Multipass")
        #expect(QEMUVMParsing.managerName(of: processes[5]) == "Podman")
        #expect(QEMUVMParsing.managerName(of: processes[6]) == "minikube")
        #expect(QEMUVMParsing.managerName(of: processes[7]) == "Vagrant")
    }

    @Test func ignoresOtherProcessesAndUnreadableArguments() {
        let processes = [
            VMHostProcess(pid: 10, parentPID: 1, name: "qemu-img", arguments: ["-name", "x"]),
            VMHostProcess(pid: 11, parentPID: 1, name: "vfkit", arguments: ["--cpus", "2"]),
            qemu(pid: 12, []),
        ]
        #expect(QEMUVMParsing.records(processes: processes).isEmpty)
    }

    @Test func idsStayUniqueAndNamesFallBack() throws {
        let records = QEMUVMParsing.records(processes: [
            qemu(pid: 20, ["-name", "same"]),
            qemu(pid: 21, ["-name", "same"]),
            qemu(pid: 22, ["-drive", "file=/vms/ubuntu-24.04.qcow2"]),
            qemu(pid: 23, ["-nographic"]),
        ])
        #expect(Set(records.map(\.nativeID)).count == 4)
        #expect(records.map(\.nativeID) == ["name-same-20", "name-same-21", "pid-22", "pid-23"])
        #expect(records[2].name == "ubuntu-24.04")
        #expect(records[3].name == "QEMU (pid 23)")
    }
}
