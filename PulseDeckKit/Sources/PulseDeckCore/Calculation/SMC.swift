import Foundation

/// Encoding and decoding for the System Management Controller's user-client protocol, as used by
/// the open-source `smc` tool (Apple's `AppleSMC` kext, selector 2 "handle YPC event"). Every call
/// exchanges one 80-byte `SMCKeyData_t` structure; field offsets follow the C layout:
///
/// | offset | field |
/// |---|---|
/// | 0 | `key` (UInt32, FourCC) |
/// | 4 | `vers` (6 bytes) |
/// | 12 | `pLimitData` (16 bytes) |
/// | 28 | `keyInfo.dataSize` (UInt32) |
/// | 32 | `keyInfo.dataType` (UInt32, FourCC) |
/// | 36 | `keyInfo.dataAttributes` (UInt8) |
/// | 40 | `result` (UInt8) |
/// | 41 | `status` (UInt8) |
/// | 42 | `data8` (UInt8, the command) |
/// | 44 | `data32` (UInt32) |
/// | 48 | `bytes` (32 bytes) |
///
/// Integers in the structure are native (little-endian on every supported Mac); the value bytes
/// use the encoding named by the key's data type.
public enum SMC {
    public static let structureSize = 80
    /// `IOConnectCallStructMethod` selector.
    public static let selector: UInt32 = 2

    public enum Command: UInt8, Sendable {
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let data32 = 44
        static let bytes = 48
    }

    static let maximumValueSize = 32

    /// "Tp09" → 0x54703039.
    public static func fourCC(_ text: String) -> UInt32? {
        let bytes = Array(text.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    public static func string(fromFourCC code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> UInt32($0)) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Input structure for `command`.
    public static func request(_ command: Command, key: UInt32 = 0, index: UInt32 = 0, dataSize: UInt32 = 0) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: structureSize)
        write(key, to: &buffer, at: Offset.key)
        write(dataSize, to: &buffer, at: Offset.dataSize)
        buffer[Offset.command] = command.rawValue
        write(index, to: &buffer, at: Offset.data32)
        return buffer
    }

    public struct KeyInfo: Hashable, Sendable {
        public var dataSize: UInt32
        /// FourCC such as "flt ", "sp78", "fpe2", "ui8 ".
        public var dataType: String
    }

    /// Non-zero `result` means the SMC rejected the request (e.g. unknown key).
    public static func result(of response: [UInt8]) -> UInt8? {
        response.count == structureSize ? response[Offset.result] : nil
    }

    public static func key(of response: [UInt8]) -> UInt32? {
        guard response.count == structureSize else { return nil }
        return read(response, at: Offset.key)
    }

    public static func keyInfo(of response: [UInt8]) -> KeyInfo? {
        guard response.count == structureSize, response[Offset.result] == 0 else { return nil }
        let size = read(response, at: Offset.dataSize)
        guard size > 0, size <= maximumValueSize else { return nil }
        return KeyInfo(dataSize: size, dataType: string(fromFourCC: read(response, at: Offset.dataType)))
    }

    public static func valueBytes(of response: [UInt8], size: UInt32) -> [UInt8]? {
        guard response.count == structureSize, response[Offset.result] == 0, size <= maximumValueSize else { return nil }
        return Array(response[Offset.bytes..<(Offset.bytes + Int(size))])
    }

    /// Decodes a value by its SMC data type. `nil` for types PulseDeck does not interpret.
    ///
    /// - `flt `: IEEE 754 Float32, little-endian (Apple silicon).
    /// - `sp78`: signed 8.8 fixed point, big-endian (Intel temperatures).
    /// - `fpe2`: unsigned 14.2 fixed point, big-endian (Intel fan speeds).
    /// - `fp88`: unsigned 8.8 fixed point, big-endian.
    /// - `ui8 `, `ui16`, `ui32`: unsigned integers, big-endian.
    public static func decode(_ bytes: [UInt8], type: String) -> Double? {
        func bigEndian(_ count: Int) -> UInt32? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case "sp78":
            return bigEndian(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "fpe2":
            return bigEndian(2).map { Double($0) / 4 }
        case "fp88":
            return bigEndian(2).map { Double($0) / 256 }
        case "ui8 ":
            return bigEndian(1).map(Double.init)
        case "ui16":
            return bigEndian(2).map(Double.init)
        case "ui32":
            return bigEndian(4).map(Double.init)
        default:
            return nil
        }
    }

    private static func write(_ value: UInt32, to buffer: inout [UInt8], at offset: Int) {
        for index in 0..<4 {
            buffer[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(8 * index))
        }
    }

    private static func read(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(buffer[offset + $1]) << UInt32(8 * $1) }
    }
}

/// Maps SMC temperature keys to board zones. Keys are "T" + a letter naming the component + two
/// characters for the sensor instance. The letters differ between Apple silicon and Intel Macs
/// and are not documented; the tables follow what open-source monitors observe. Unknown letters
/// stay unclassified and are not shown rather than guessed.
public enum ThermalClassifier {
    public enum Architecture: Sendable {
        case appleSilicon
        case intel
    }

    /// Readings outside this range are sensor placeholders (0, −127, 255 …), not temperatures.
    public static let plausibleCelsius = 1.0...130.0

    public static func zone(ofKey key: String, architecture: Architecture) -> ThermalZone? {
        let characters = Array(key)
        guard characters.count == 4, characters[0] == "T" else { return nil }
        switch architecture {
        case .appleSilicon:
            switch characters[1] {
            case "p": return .cpuPerformance
            case "e": return .cpuEfficiency
            case "g": return .gpu
            case "m": return .memory
            case "H": return .storage
            case "W": return .wireless
            case "B": return .battery
            case "V", "D": return .power
            case "a", "A": return .ambient
            case "s": return .enclosure
            default: return nil
            }
        case .intel:
            switch characters[1] {
            case "C": return .cpu
            case "G": return .gpu
            case "M", "m": return .memory
            case "H": return .storage
            case "W": return .wireless
            case "B": return .battery
            case "p", "V": return .power
            case "A", "a": return .ambient
            case "s": return .enclosure
            default: return nil
            }
        }
    }

    public static func isPlausible(_ celsius: Double) -> Bool {
        plausibleCelsius.contains(celsius)
    }
}
