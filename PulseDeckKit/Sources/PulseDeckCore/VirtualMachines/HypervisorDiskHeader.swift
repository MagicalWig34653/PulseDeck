import Foundation

/// Reads the *virtual* (guest-visible) size of a disk image from the first bytes of the file.
/// The size of the file on the host is not that value for sparse or compressed formats, and
/// running `qemu-img`/`VBoxManage` just to list a VM would be shell polling.
///
/// Supported headers (layouts from the formats' public specifications):
/// - QCOW2: magic `QFI\xfb`, big-endian; virtual size is the u64 at offset 24.
/// - VDI (VirtualBox): signature `0xBEDA107F` (little-endian) at offset 0x40; disk size is the u64 at 0x170.
/// - VMDK sparse extent: magic `KDMV`; capacity in 512-byte sectors is the u64 at offset 12.
/// - VMDK text descriptor: `RW <sectors> <type> "<file>"` extent lines (split / flat disks).
public enum HypervisorDiskHeader {
    /// Number of bytes a caller has to read from the start of the file to decide.
    /// 0x178 covers the VDI field, the whole descriptor of a text VMDK is read separately.
    public static let headerLength = 0x178

    /// Size of a text VMDK descriptor we are willing to read (descriptors are a few hundred bytes).
    public static let maximumDescriptorLength = 65_536

    private static let sectorSize: UInt64 = 512

    /// Virtual size in bytes, or `nil` when the bytes are not a known image header (for
    /// example a raw image, whose size is simply the file size).
    public static func virtualSize(header: Data) -> UInt64? {
        let bytes = [UInt8](header)
        if bytes.count >= 32, bytes[0] == 0x51, bytes[1] == 0x46, bytes[2] == 0x49, bytes[3] == 0xFB {
            return readUInt64(bytes, at: 24, bigEndian: true)
        }
        if bytes.count >= 0x178, readUInt32(bytes, at: 0x40, bigEndian: false) == 0xBEDA_107F {
            return readUInt64(bytes, at: 0x170, bigEndian: false)
        }
        if bytes.count >= 20, bytes[0] == 0x4B, bytes[1] == 0x44, bytes[2] == 0x4D, bytes[3] == 0x56 {
            guard let sectors = readUInt64(bytes, at: 12, bigEndian: false) else { return nil }
            return sectors.multipliedReportingOverflow(by: sectorSize).overflow ? nil : sectors * sectorSize
        }
        return nil
    }

    /// Sum of the extents of a text VMDK descriptor, or `nil` if `text` is not one.
    public static func vmdkDescriptorSize(_ text: String) -> UInt64? {
        guard text.hasPrefix("# Disk DescriptorFile") else { return nil }
        var sectors: UInt64 = 0
        var found = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, ["RW", "RDONLY", "NOACCESS"].contains(String(parts[0])), let count = UInt64(parts[1]) else { continue }
            let (sum, overflow) = sectors.addingReportingOverflow(count)
            if overflow { return nil }
            sectors = sum
            found = true
        }
        guard found else { return nil }
        let (bytes, overflow) = sectors.multipliedReportingOverflow(by: sectorSize)
        return overflow ? nil : bytes
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            let byte = UInt32(bytes[offset + (bigEndian ? index : 3 - index)])
            value = (value << 8) | byte
        }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            let byte = UInt64(bytes[offset + (bigEndian ? index : 7 - index)])
            value = (value << 8) | byte
        }
        return value
    }
}
