#if os(macOS)
import Darwin

/// Typed wrappers around `sysctlbyname(3)`.
enum Sysctl {
    /// Reads a fixed-width integer. Returns `nil` if the name does not exist or its size does
    /// not match `T` (guards against reading e.g. a 64-bit value into 32 bits).
    static func integer<T: FixedWidthInteger>(_ name: String, as type: T.Type = T.self) -> T? {
        var value: T = 0
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else {
            return nil
        }
        return value
    }

    /// Reads a C string value.
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Reads a C struct value of exactly `MemoryLayout<T>.size` bytes.
    static func structure<T: BitwiseCopyable>(_ name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutableBytes(of: &value) { bytes in
            sysctlbyname(name, bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<T>.size else {
            return nil
        }
        return value
    }
}
#endif
