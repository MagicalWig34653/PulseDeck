#if os(macOS)
import Foundation
import PulseDeckCore

/// Read-only file-system helpers and result mapping shared by the Tart / UTM / Parallels /
/// VMware Fusion / VirtualBox / Anka adapters. Deliberately dumb: everything that interprets
/// the bytes lives in `PulseDeckCore` and is unit tested there.
enum VMProviderFiles {
    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func data(at path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    static func text(at path: String) -> String? {
        data(at: path).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// File names (not paths) in a directory, sorted; empty when it cannot be read.
    static func entries(in directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    /// Logical file length (sparse files report their full length, not the blocks in use).
    static func fileSize(at path: String) -> UInt64? {
        guard let size = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size >= 0 else { return nil }
        return UInt64(size)
    }

    /// The first `length` bytes of a file.
    static func prefix(of path: String, length: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: length)
    }

    /// `CFBundleShortVersionString` of an app bundle, read from its `Info.plist` (nothing is run).
    static func appVersion(bundlePath: String) -> String? {
        guard let data = data(at: bundlePath + "/Contents/Info.plist"),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let info = object as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The provider's own identifier of a VM (`VirtualMachineSnapshot.id` is `"<provider>:<native id>"`).
    static func nativeID(of machine: VirtualMachineSnapshot) -> String {
        let prefix = machine.providerID + ":"
        return machine.id.hasPrefix(prefix) ? String(machine.id.dropFirst(prefix.count)) : machine.id
    }

    /// Virtual size of a disk image file: from its header when it is a known sparse / compressed
    /// format, otherwise `nil`.
    static func virtualDiskSize(at path: String) -> UInt64? {
        guard let header = prefix(of: path, length: HypervisorDiskHeader.headerLength) else { return nil }
        return HypervisorDiskHeader.virtualSize(header: header)
    }

    /// Maps the outcome of a tool run to the adapter result type.
    static func outcome(_ result: VMCommandResult?) -> Result<Void, VMControlError> {
        guard let result else { return .failure(.providerUnavailable) }
        if result.succeeded { return .success(()) }
        let message = [result.standardError, result.standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return .failure(.failed(message ?? "The tool exited with status \(result.exitStatus)."))
    }
}
#endif
