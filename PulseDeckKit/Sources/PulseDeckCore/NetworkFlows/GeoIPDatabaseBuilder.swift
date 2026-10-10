import Foundation

/// Writes `GeoIP.bin` (format version 1, described in `GeoIPDatabase.swift`). The production file is
/// produced by `scripts/build-geoip.py`; this writer exists so tests can build small databases and so
/// both writers can be checked against the one reader.
public struct GeoIPDatabaseBuilder: Sendable {
    public enum BuildError: Error, Equatable, Sendable {
        case invalidCountryCode(String)
        case invalidProviderName(String)
        case overlappingRanges
        case tooManyCountriesOrProviders
    }

    private struct Entry {
        var first: UInt64
        var last: UInt64
        var country: String?
        var provider: String?
    }

    private static let ipv6KeyBytes = 6
    private static let bucketCount = 256

    private var ipv4: [Entry] = []
    private var ipv6: [Entry] = []
    private let dataDate: UInt32

    /// - Parameter dataDate: YYYYMMDD of the source data (informational).
    public init(dataDate: UInt32 = 0) {
        self.dataDate = dataDate
    }

    /// Adds an inclusive IPv4 range. `countryCode` is ISO alpha-2 in capitals or `nil`.
    public mutating func addIPv4(first: UInt32, last: UInt32, countryCode: String?, provider: String?) {
        ipv4.append(Entry(first: UInt64(first), last: UInt64(last), country: countryCode, provider: provider))
    }

    /// Adds an inclusive range of IPv6 /48 prefixes (`first`/`last` are the top 48 bits of the addresses).
    public mutating func addIPv6(firstPrefix: UInt64, lastPrefix: UInt64, countryCode: String?, provider: String?) {
        ipv6.append(Entry(first: firstPrefix, last: lastPrefix, country: countryCode, provider: provider))
    }

    /// Adds a CIDR block ("17.0.0.0/8", "2606:4700::/32"). Returns `false` if the text is not a valid
    /// block, or if an IPv6 block is longer than /48 (not representable).
    @discardableResult
    public mutating func addPrefix(_ cidr: String, countryCode: String?, provider: String?) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let length = Int(parts[1]), let address = IPAddress(String(parts[0])) else { return false }
        switch address {
        case .v4(let value):
            guard (0...32).contains(length) else { return false }
            let hostBits = UInt32(32 - length)
            let mask: UInt32 = hostBits == 32 ? 0 : ~0 << hostBits
            let first = value & mask
            addIPv4(first: first, last: first | ~mask, countryCode: countryCode, provider: provider)
        case .v6(let high, _):
            guard (0...48).contains(length) else { return false }
            let prefix = high >> 16
            let hostBits = UInt64(48 - length)
            let first = (prefix >> hostBits) << hostBits
            addIPv6(firstPrefix: first, lastPrefix: first | ((1 << hostBits) - 1), countryCode: countryCode, provider: provider)
        }
        return true
    }

    /// Serialises the database. Ranges may be added in any order but must not overlap; adjacent ranges with
    /// the same country and provider are merged and gaps become explicit "unknown" entries.
    public func build() throws -> Data {
        let ipv4Entries = try Self.normalise(ipv4, maxKey: UInt64(UInt32.max))
        let ipv6Entries = try Self.normalise(ipv6, maxKey: (1 << 48) - 1)
        let countries = Set((ipv4Entries + ipv6Entries).compactMap(\.country)).sorted()
        let providers = Set((ipv4Entries + ipv6Entries).compactMap(\.provider)).sorted()
        for code in countries {
            let scalars = Array(code.utf8)
            guard scalars.count == 2, scalars.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }) else {
                throw BuildError.invalidCountryCode(code)
            }
        }
        for name in providers where name.isEmpty { throw BuildError.invalidProviderName(name) }
        guard countries.count < 256, providers.count < 256 else { throw BuildError.tooManyCountriesOrProviders }
        let countryIndex = Dictionary(uniqueKeysWithValues: countries.enumerated().map { ($1, UInt8($0 + 1)) })
        let providerIndex = Dictionary(uniqueKeysWithValues: providers.enumerated().map { ($1, UInt8($0 + 1)) })

        var countryTable: [UInt8] = [0, 0]
        for code in countries { countryTable += Array(code.utf8) }
        var providerOffsets: [UInt32] = [0, 0]
        var blob: [UInt8] = []
        for name in providers {
            blob += Array(name.utf8)
            providerOffsets.append(UInt32(blob.count))
        }
        var providerTable: [UInt8] = []
        for offset in providerOffsets { Self.append(offset, to: &providerTable) }
        providerTable += blob

        let ipv4Section = Self.section(ipv4Entries, keyBytes: 4, countryIndex: countryIndex, providerIndex: providerIndex)
        let ipv6Section = Self.section(ipv6Entries, keyBytes: Self.ipv6KeyBytes, countryIndex: countryIndex, providerIndex: providerIndex)

        let headerSize = 48
        let countryOffset = headerSize
        let providerOffset = countryOffset + countryTable.count
        let ipv4Offset = providerOffset + providerTable.count
        let ipv6Offset = ipv4Offset + ipv4Section.bytes.count
        let fileSize = ipv6Offset + ipv6Section.bytes.count

        var output: [UInt8] = Array("PDGI".utf8)
        Self.append(UInt16(1), to: &output)
        Self.append(UInt16(headerSize), to: &output)
        Self.append(dataDate, to: &output)
        Self.append(UInt32(ipv4Section.count), to: &output)
        Self.append(UInt32(ipv6Section.count), to: &output)
        Self.append(UInt16(countries.count + 1), to: &output)
        Self.append(UInt16(providers.count + 1), to: &output)
        output += [UInt8(Self.ipv6KeyBytes), 0, 0, 0]
        for value in [countryOffset, providerOffset, ipv4Offset, ipv6Offset, fileSize] {
            Self.append(UInt32(value), to: &output)
        }
        output += countryTable
        output += providerTable
        output += ipv4Section.bytes
        output += ipv6Section.bytes
        return Data(output)
    }

    // MARK: Normalisation

    private struct Payload: Equatable {
        var country: String?
        var provider: String?
    }

    /// Sorted, non-overlapping, adjacent-merged entries as (start, payload) with explicit gaps.
    private static func normalise(_ entries: [Entry], maxKey: UInt64) throws -> [Entry] {
        let sorted = entries.sorted { $0.first < $1.first }
        guard !sorted.isEmpty else { return [] }
        var result: [Entry] = []
        var cursor: UInt64 = 0   // next key not yet covered
        var covered = false
        func append(first: UInt64, last: UInt64, payload: Payload) {
            if let tail = result.last, tail.last &+ 1 == first, tail.country == payload.country, tail.provider == payload.provider {
                result[result.count - 1].last = last
            } else {
                result.append(Entry(first: first, last: last, country: payload.country, provider: payload.provider))
            }
        }
        for entry in sorted {
            guard entry.first <= entry.last, entry.last <= maxKey else { throw BuildError.overlappingRanges }
            if covered, entry.first < cursor { throw BuildError.overlappingRanges }
            if entry.first > cursor { append(first: cursor, last: entry.first - 1, payload: Payload()) }
            append(first: entry.first, last: entry.last, payload: Payload(country: entry.country, provider: entry.provider))
            covered = true
            cursor = entry.last + 1
        }
        if let tail = result.last, tail.last < maxKey {
            append(first: tail.last + 1, last: maxKey, payload: Payload())
        }
        return result
    }

    private static func section(
        _ entries: [Entry], keyBytes: Int, countryIndex: [String: UInt8], providerIndex: [String: UInt8]
    ) -> (bytes: [UInt8], count: Int) {
        // Split so that every bucket (top key byte) starts at low key 0.
        let shift = UInt64(8 * (keyBytes - 1))
        var split: [(start: UInt64, country: String?, provider: String?)] = []
        if !entries.isEmpty {
            var position = 0
            for bucket in 0..<bucketCount {
                let boundary = UInt64(bucket) << shift
                while position + 1 < entries.count, entries[position + 1].first <= boundary { position += 1 }
                if entries[position].first != boundary {
                    split.append((boundary, entries[position].country, entries[position].provider))
                }
                var scan = position
                while scan < entries.count, entries[scan].first < boundary + (1 << shift) {
                    if entries[scan].first >= boundary {
                        split.append((entries[scan].first, entries[scan].country, entries[scan].provider))
                    }
                    scan += 1
                }
            }
        }
        var index = [UInt32](repeating: 0, count: bucketCount + 1)
        for item in split { index[Int(item.start >> shift) + 1] += 1 }
        for bucket in 0..<bucketCount { index[bucket + 1] += index[bucket] }
        var bytes: [UInt8] = []
        for value in index { append(value, to: &bytes) }
        let lowMask = (UInt64(1) << shift) - 1
        for item in split {
            let low = item.start & lowMask
            for byteIndex in (0..<(keyBytes - 1)).reversed() {
                bytes.append(UInt8(truncatingIfNeeded: low >> UInt64(byteIndex * 8)))
            }
        }
        for item in split { bytes.append(item.country.flatMap { countryIndex[$0] } ?? 0) }
        for item in split { bytes.append(item.provider.flatMap { providerIndex[$0] } ?? 0) }
        return (bytes, split.count)
    }

    private static func append(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func append(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
}
