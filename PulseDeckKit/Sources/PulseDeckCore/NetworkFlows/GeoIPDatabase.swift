import Foundation

// GeoIP.bin — PulseDeck's offline IP → (country, provider) database, format version 1.
//
// Written by `scripts/build-geoip.py` (the production file) and by `GeoIPDatabaseBuilder` (tests); both
// must stay in sync with this description (also in docs/GEOIP.md). Every multi-byte integer is
// BIG-ENDIAN, there is no padding, and the whole file is contiguous in the order below.
//
//   Header (48 bytes)
//     0   4  magic "PDGI"
//     4   2  format version (1)
//     6   2  header size (48)
//     8   4  data date, YYYYMMDD (informational)
//    12   4  IPv4 entry count
//    16   4  IPv6 entry count
//    20   2  country table entries (>= 1; entry 0 is "unknown")
//    22   2  provider table entries (>= 1; entry 0 is "unknown")
//    24   1  IPv6 key bytes (6: the top 48 bits of an address)
//    25   3  reserved, zero
//    28   4  country table offset (= 48)
//    32   4  provider table offset
//    36   4  IPv4 section offset
//    40   4  IPv6 section offset
//    44   4  file size
//   Country table: countryCount × 2 ASCII bytes ("DE"); entry 0 is two zero bytes.
//   Provider table: (providerCount + 1) × UInt32 string end offsets (the first is 0), then the UTF-8
//     string blob; provider i is blob[offset[i] ..< offset[i+1]]; provider 0 is empty ("unknown").
//   Address section (IPv4 with 4-byte keys, IPv6 with 6-byte keys), `count` entries:
//     257 × UInt32 bucket index: bucket b holds the entries whose key's top byte is b; the entries of
//       bucket b are index[b] ..< index[b+1] (index[0] = 0, index[256] = count).
//     count × (keyBytes − 1) bytes: the key without its top byte ("low key"), increasing in a bucket.
//     count × UInt8 country index, count × UInt8 provider index.
//   An entry covers its key up to (not including) the next entry's key; the last entry reaches the end
//   of the address space. Gaps (no data) are explicit entries with country 0 and provider 0. When
//   count > 0, every bucket is non-empty and starts with low key 0, so a lookup never leaves its bucket.
//
// Lookups are a bucket index plus one binary search. A corrupt or truncated file is rejected as a whole
// by `init(data:)` (every offset, index and ordering rule above is checked once), so lookups on a
// loaded database cannot go out of bounds.

/// Why a `GeoIPDatabase` could not be loaded.
public enum GeoIPDatabaseError: Error, Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedVersion(UInt16)
    case invalidHeader
    case invalidCountryTable
    case invalidProviderTable
    case invalidSection(String)
}

/// Read-only view of a `GeoIP.bin` (see the format description above).
public struct GeoIPDatabase: Sendable {
    /// What the database knows about an address. Both fields are `nil` when unknown.
    public struct Record: Hashable, Sendable {
        public var countryCode: String?
        public var provider: String?

        public init(countryCode: String? = nil, provider: String? = nil) {
            self.countryCode = countryCode
            self.provider = provider
        }
    }

    public struct Metadata: Hashable, Sendable {
        public var formatVersion: Int
        /// YYYYMMDD of the source data, 0 when unknown.
        public var dataDate: Int
        public var ipv4EntryCount: Int
        public var ipv6EntryCount: Int
        public var countryCount: Int
        public var providerCount: Int
    }

    public let metadata: Metadata

    private struct Section: Sendable {
        var count: Int
        var keyBytes: Int
        var bucketIndex: Int
        var lowKeys: Int
        var countries: Int
        var providers: Int

        static let bucketCount = 256
        static let bucketIndexBytes = (bucketCount + 1) * 4

        /// Byte size of a section with `count` entries, or `nil` on overflow.
        static func size(count: Int, keyBytes: Int) -> Int? {
            let (perEntry, overflow1) = (keyBytes - 1).addingReportingOverflow(2)
            let (entries, overflow2) = perEntry.multipliedReportingOverflow(by: count)
            let (total, overflow3) = entries.addingReportingOverflow(bucketIndexBytes)
            return overflow1 || overflow2 || overflow3 ? nil : total
        }
    }

    private static let headerSize = 48
    private static let magic: [UInt8] = Array("PDGI".utf8)
    private static let ipv4KeyBytes = 4

    private let bytes: [UInt8]
    private let countryCodes: [String?]
    private let providerNames: [String?]
    private let ipv4: Section
    private let ipv6: Section

    /// Validates and loads `data`.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize else { throw GeoIPDatabaseError.truncated }
        guard Array(bytes[0..<4]) == Self.magic else { throw GeoIPDatabaseError.badMagic }
        let version = Self.readUInt16(bytes, 4)
        guard version == 1 else { throw GeoIPDatabaseError.unsupportedVersion(version) }
        guard Self.readUInt16(bytes, 6) == Self.headerSize else { throw GeoIPDatabaseError.invalidHeader }
        let dataDate = Int(Self.readUInt32(bytes, 8))
        let ipv4Count = Int(Self.readUInt32(bytes, 12))
        let ipv6Count = Int(Self.readUInt32(bytes, 16))
        let countryCount = Int(Self.readUInt16(bytes, 20))
        let providerCount = Int(Self.readUInt16(bytes, 22))
        let ipv6KeyBytes = Int(bytes[24])
        let countryOffset = Int(Self.readUInt32(bytes, 28))
        let providerOffset = Int(Self.readUInt32(bytes, 32))
        let ipv4Offset = Int(Self.readUInt32(bytes, 36))
        let ipv6Offset = Int(Self.readUInt32(bytes, 40))
        let fileSize = Int(Self.readUInt32(bytes, 44))
        guard fileSize == bytes.count else { throw GeoIPDatabaseError.truncated }
        guard countryCount >= 1, providerCount >= 1, (2...8).contains(ipv6KeyBytes),
              bytes[25] == 0, bytes[26] == 0, bytes[27] == 0,
              countryOffset == Self.headerSize
        else { throw GeoIPDatabaseError.invalidHeader }

        // Country table.
        guard providerOffset == countryOffset + countryCount * 2, providerOffset <= bytes.count else {
            throw GeoIPDatabaseError.invalidCountryTable
        }
        var countries: [String?] = [nil]
        guard bytes[countryOffset] == 0, bytes[countryOffset + 1] == 0 else { throw GeoIPDatabaseError.invalidCountryTable }
        for index in 1..<countryCount {
            let first = bytes[countryOffset + index * 2]
            let second = bytes[countryOffset + index * 2 + 1]
            let upper = UInt8(ascii: "A")...UInt8(ascii: "Z")
            guard upper.contains(first), upper.contains(second) else { throw GeoIPDatabaseError.invalidCountryTable }
            countries.append(String(decoding: [first, second], as: UTF8.self))
        }

        // Provider table: UInt32 end offsets, then the blob, which ends exactly where the IPv4 section starts.
        let blobStart = providerOffset + (providerCount + 1) * 4
        guard blobStart <= bytes.count else { throw GeoIPDatabaseError.invalidProviderTable }
        let offsets = (0...providerCount).map { Int(Self.readUInt32(bytes, providerOffset + $0 * 4)) }
        guard offsets[0] == 0, offsets[1] == 0,   // provider 0 ("unknown") is empty
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }),
              blobStart + offsets[providerCount] == ipv4Offset, ipv4Offset <= bytes.count
        else { throw GeoIPDatabaseError.invalidProviderTable }
        var providers: [String?] = [nil]
        for index in 1..<providerCount {
            let (lower, upper) = (blobStart + offsets[index], blobStart + offsets[index + 1])
            guard upper > lower else { throw GeoIPDatabaseError.invalidProviderTable }   // names are non-empty
            providers.append(String(decoding: bytes[lower..<upper], as: UTF8.self))
        }

        // Address sections.
        guard let ipv4Size = Section.size(count: ipv4Count, keyBytes: Self.ipv4KeyBytes),
              let ipv6Size = Section.size(count: ipv6Count, keyBytes: ipv6KeyBytes),
              ipv6Offset == ipv4Offset + ipv4Size,
              fileSize == ipv6Offset + ipv6Size
        else { throw GeoIPDatabaseError.invalidSection("size") }
        let ipv4Section = Self.makeSection(offset: ipv4Offset, count: ipv4Count, keyBytes: Self.ipv4KeyBytes)
        let ipv6Section = Self.makeSection(offset: ipv6Offset, count: ipv6Count, keyBytes: ipv6KeyBytes)
        try Self.validate(ipv4Section, name: "IPv4", bytes: bytes, countryCount: countryCount, providerCount: providerCount)
        try Self.validate(ipv6Section, name: "IPv6", bytes: bytes, countryCount: countryCount, providerCount: providerCount)

        self.bytes = bytes
        self.countryCodes = countries
        self.providerNames = providers
        self.ipv4 = ipv4Section
        self.ipv6 = ipv6Section
        self.metadata = Metadata(formatVersion: Int(version), dataDate: dataDate, ipv4EntryCount: ipv4Count,
                                 ipv6EntryCount: ipv6Count, countryCount: countryCount - 1, providerCount: providerCount - 1)
    }

    /// Looks the address up. Addresses that are not covered (or any IPv6 address on an empty IPv6
    /// section) return an empty record. IPv4-mapped and NAT64 IPv6 addresses are looked up as IPv4.
    public func lookup(_ address: IPAddress) -> Record {
        if let embedded = address.embeddedIPv4 {
            return record(in: ipv4, key: UInt64(embedded))
        }
        // IPv6 keys are the top `keyBytes` bytes of the address (6 → the 48-bit prefix).
        guard case .v6(let high, _) = address else { return Record() }
        return record(in: ipv6, key: high >> UInt64(64 - ipv6.keyBytes * 8))
    }

    // MARK: Lookup

    private func record(in section: Section, key: UInt64) -> Record {
        guard section.count > 0 else { return Record() }
        let lowBytes = section.keyBytes - 1
        let shift = UInt64(lowBytes * 8)
        let bucket = Int(key >> shift)
        guard bucket < Section.bucketCount else { return Record() }
        let low = key & ((1 << shift) - 1)
        var lower = Int(Self.readUInt32(bytes, section.bucketIndex + bucket * 4))
        var upper = Int(Self.readUInt32(bytes, section.bucketIndex + (bucket + 1) * 4))
        // Last entry in [lower, upper) whose low key is <= `low` (the first entry's low key is 0).
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if Self.readKey(bytes, section.lowKeys + middle * lowBytes, lowBytes) <= low {
                lower = middle
            } else {
                upper = middle
            }
        }
        let country = Int(bytes[section.countries + lower])
        let provider = Int(bytes[section.providers + lower])
        return Record(countryCode: countryCodes[country], provider: providerNames[provider])
    }

    // MARK: Validation

    private static func makeSection(offset: Int, count: Int, keyBytes: Int) -> Section {
        let lowKeys = offset + Section.bucketIndexBytes
        let countries = lowKeys + count * (keyBytes - 1)
        return Section(count: count, keyBytes: keyBytes, bucketIndex: offset, lowKeys: lowKeys,
                       countries: countries, providers: countries + count)
    }

    private static func validate(_ section: Section, name: String, bytes: [UInt8], countryCount: Int, providerCount: Int) throws {
        let lowBytes = section.keyBytes - 1
        var previousIndex = 0
        for bucket in 0...Section.bucketCount {
            let index = Int(readUInt32(bytes, section.bucketIndex + bucket * 4))
            // Monotone, never past the end; first is 0, last is count.
            guard index >= previousIndex, index <= section.count,
                  bucket != 0 || index == 0,
                  bucket != Section.bucketCount || index == section.count
            else { throw GeoIPDatabaseError.invalidSection("\(name) bucket index") }
            previousIndex = index
        }
        guard section.count > 0 else { return }
        for bucket in 0..<Section.bucketCount {
            let lower = Int(readUInt32(bytes, section.bucketIndex + bucket * 4))
            let upper = Int(readUInt32(bytes, section.bucketIndex + (bucket + 1) * 4))
            // Every bucket starts at low key 0 and is strictly increasing.
            guard upper > lower, readKey(bytes, section.lowKeys + lower * lowBytes, lowBytes) == 0 else {
                throw GeoIPDatabaseError.invalidSection("\(name) bucket \(bucket) does not start at 0")
            }
            var previous: UInt64?
            for entry in lower..<upper {
                let key = readKey(bytes, section.lowKeys + entry * lowBytes, lowBytes)
                if let previous, key <= previous { throw GeoIPDatabaseError.invalidSection("\(name) keys not increasing") }
                previous = key
            }
        }
        for entry in 0..<section.count {
            guard Int(bytes[section.countries + entry]) < countryCount, Int(bytes[section.providers + entry]) < providerCount else {
                throw GeoIPDatabaseError.invalidSection("\(name) index out of range")
            }
        }
    }

    // MARK: Big-endian reads (callers have validated the bounds)

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func readKey(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<length { value = value << 8 | UInt64(bytes[offset + index]) }
        return value
    }
}
