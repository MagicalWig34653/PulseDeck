import Foundation
import Testing
@testable import PulseDeckCore

// MARK: - IP parsing

@Suite("IP address parsing")
struct IPAddressParsingTests {
    @Test func parsesIPv4() {
        #expect(IPAddress("0.0.0.0") == .v4(0))
        #expect(IPAddress("1.2.3.4") == .v4(0x0102_0304))
        #expect(IPAddress("255.255.255.255") == .v4(0xFFFF_FFFF))
        #expect(IPAddress("192.168.0.1") == .v4(0xC0A8_0001))
    }

    @Test func rejectsMalformedIPv4() {
        for text in ["", " ", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.256", "01.2.3.4", "1.2.3.04", "1..3.4",
                     ".1.2.3", "1.2.3.", "a.b.c.d", "1.2.3.4 ", "1.2.3.-4", "1.2.3.4000", "example.com", "1.2.3.4:80", "0x7f.0.0.1"] {
            #expect(IPAddress(text) == nil, "\(text) should not parse")
        }
    }

    @Test func parsesIPv6Forms() {
        #expect(IPAddress("::") == .v6(high: 0, low: 0))
        #expect(IPAddress("::1") == .v6(high: 0, low: 1))
        #expect(IPAddress("2001:db8::1") == .v6(high: 0x2001_0DB8_0000_0000, low: 1))
        #expect(IPAddress("2001:0db8:0000:0000:0000:0000:0000:0001") == IPAddress("2001:db8::1"))
        #expect(IPAddress("2001:DB8::ABCD") == IPAddress("2001:db8::abcd"))
        #expect(IPAddress("fe80::1") == .v6(high: 0xFE80_0000_0000_0000, low: 1))
        #expect(IPAddress("1::") == .v6(high: 0x0001_0000_0000_0000, low: 0))
        #expect(IPAddress("1:2:3:4:5:6:7:8") == .v6(high: 0x0001_0002_0003_0004, low: 0x0005_0006_0007_0008))
        #expect(IPAddress("1:2:3:4:5:6:7::") == .v6(high: 0x0001_0002_0003_0004, low: 0x0005_0006_0007_0000))
        #expect(IPAddress("::2:3:4:5:6:7:8") == .v6(high: 0x0000_0002_0003_0004, low: 0x0005_0006_0007_0008))
    }

    @Test func parsesEmbeddedIPv4AndZones() {
        #expect(IPAddress("::ffff:1.2.3.4") == .v6(high: 0, low: 0x0000_FFFF_0102_0304))
        #expect(IPAddress("::FFFF:192.168.1.1")?.embeddedIPv4 == 0xC0A8_0101)
        #expect(IPAddress("64:ff9b::8.8.8.8")?.embeddedIPv4 == 0x0808_0808)
        #expect(IPAddress("1:2:3:4:5:6:1.2.3.4") == .v6(high: 0x0001_0002_0003_0004, low: 0x0005_0006_0102_0304))
        #expect(IPAddress("fe80::1%en0") == IPAddress("fe80::1"))
        #expect(IPAddress("2001:db8::1")?.embeddedIPv4 == nil)
        #expect(IPAddress("1.2.3.4")?.embeddedIPv4 == 0x0102_0304)
    }

    @Test func rejectsMalformedIPv6() {
        for text in [":", ":::", "1:::2", "1::2::3", "12345::1", "g::1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9",
                     "1:2:3:4:5:6:7:8::", "::1:2:3:4:5:6:7:8", ":1:2:3:4:5:6:7", "1:2:3:4:5:6:7:", "2001:db8::1.2.3",
                     "1.2.3.4::1", "::1.2.3.4:5", "2001:db8:::1", "[::1]", "::1/128", "fe80::1%"] {
            #expect(IPAddress(text) == nil, "\(text) should not parse")
        }
    }

    @Test func prefix48() {
        #expect(IPAddress("2606:4700:4700::1111")?.ipv6Prefix48 == 0x2606_4700_4700)
        #expect(IPAddress("1.2.3.4")?.ipv6Prefix48 == nil)
    }
}

// MARK: - Scope

@Suite("Address scope")
struct AddressScopeTests {
    @Test(arguments: [
        ("127.0.0.1", DestinationScope.loopback), ("127.255.255.254", .loopback), ("::1", .loopback),
        ("169.254.1.1", .linkLocal), ("fe80::1", .linkLocal), ("febf::1", .linkLocal), ("fe80::1%en0", .linkLocal),
        ("224.0.0.251", .multicast), ("239.255.255.250", .multicast), ("ff02::fb", .multicast),
        ("10.1.2.3", .localNetwork), ("172.16.0.1", .localNetwork), ("172.31.255.255", .localNetwork),
        ("192.168.178.1", .localNetwork), ("fd00::1", .localNetwork), ("fc00::1", .localNetwork),
        ("255.255.255.255", .localNetwork), ("198.18.0.5", .localNetwork),
        ("100.64.0.1", .tailscale), ("100.127.255.255", .tailscale), ("fd7a:115c:a1e0::1", .tailscale),
        ("fd7a:115c:a1e0:ab12:4843:cd96:625b:1234", .tailscale),
        ("0.0.0.0", .unspecified), ("::", .unspecified),
        ("::ffff:127.0.0.1", .loopback), ("::ffff:192.168.1.1", .localNetwork), ("::ffff:8.8.8.8", .internet),
        ("64:ff9b::a00:1", .localNetwork),
        ("8.8.8.8", .internet), ("172.15.0.1", .internet), ("172.32.0.1", .internet), ("100.63.255.255", .internet),
        ("100.128.0.1", .internet), ("192.169.0.1", .internet), ("198.20.0.1", .internet), ("11.0.0.1", .internet),
        ("2606:4700:4700::1111", .internet), ("2001:db8::1", .internet), ("fd7b::1", .localNetwork), ("fec0::1", .localNetwork),
    ])
    func scopes(address: String, expected: DestinationScope) {
        #expect(AddressScopeClassifier.scope(of: address) == expected, "\(address)")
    }

    @Test func nonAddressHasNoScope() {
        #expect(AddressScopeClassifier.scope(of: "example.com") == nil)
    }
}

// MARK: - Database

private func smallBuilder() -> GeoIPDatabaseBuilder {
    var builder = GeoIPDatabaseBuilder(dataDate: 20_261_009)
    builder.addPrefix("17.0.0.0/8", countryCode: "US", provider: "Apple")
    builder.addPrefix("1.1.1.0/24", countryCode: "AU", provider: "Cloudflare")
    builder.addPrefix("1.0.0.0/24", countryCode: "AU", provider: "Cloudflare")
    builder.addPrefix("80.0.0.0/7", countryCode: "DE", provider: "Deutsche Telekom")   // spans the /8 buckets 80 and 81
    builder.addPrefix("93.184.216.0/24", countryCode: "FR", provider: nil)
    builder.addPrefix("203.0.113.0/24", countryCode: nil, provider: "Example Net")
    builder.addPrefix("255.255.255.0/24", countryCode: "ZA", provider: nil)            // last addresses of the space
    builder.addPrefix("2606:4700::/32", countryCode: "US", provider: "Cloudflare")
    builder.addPrefix("2a00:1450::/32", countryCode: "IE", provider: "Google")
    return builder
}

private func smallDatabase() throws -> Data {
    try smallBuilder().build()
}

@Suite("GeoIP database")
struct GeoIPDatabaseTests {
    @Test func roundTrip() throws {
        let database = try GeoIPDatabase(data: smallDatabase())
        func lookup(_ text: String) throws -> GeoIPDatabase.Record {
            database.lookup(try #require(IPAddress(text)))
        }
        #expect(try lookup("17.253.144.10") == .init(countryCode: "US", provider: "Apple"))
        #expect(try lookup("17.0.0.0") == .init(countryCode: "US", provider: "Apple"))
        #expect(try lookup("17.255.255.255") == .init(countryCode: "US", provider: "Apple"))
        #expect(try lookup("16.255.255.255") == .init())
        #expect(try lookup("18.0.0.0") == .init())
        #expect(try lookup("1.1.1.1") == .init(countryCode: "AU", provider: "Cloudflare"))
        #expect(try lookup("1.0.0.255") == .init(countryCode: "AU", provider: "Cloudflare"))
        #expect(try lookup("1.0.1.0") == .init())
        #expect(try lookup("0.0.0.0") == .init())
        // 80.0.0.0/7 crosses a bucket (top byte) boundary: both halves must resolve.
        #expect(try lookup("80.255.255.255") == .init(countryCode: "DE", provider: "Deutsche Telekom"))
        #expect(try lookup("81.0.0.0") == .init(countryCode: "DE", provider: "Deutsche Telekom"))
        #expect(try lookup("82.0.0.0") == .init())
        #expect(try lookup("93.184.216.34") == .init(countryCode: "FR", provider: nil))
        #expect(try lookup("203.0.113.9") == .init(countryCode: nil, provider: "Example Net"))
        #expect(try lookup("255.255.255.255") == .init(countryCode: "ZA", provider: nil))
        #expect(try lookup("2606:4700:4700::1111") == .init(countryCode: "US", provider: "Cloudflare"))
        #expect(try lookup("2a00:1450:4001:81b::200e") == .init(countryCode: "IE", provider: "Google"))
        #expect(try lookup("2a00:1451::1") == .init())
        #expect(try lookup("::1") == .init())
        // IPv4-mapped and NAT64 addresses use the IPv4 table.
        #expect(try lookup("::ffff:17.1.2.3") == .init(countryCode: "US", provider: "Apple"))
        #expect(try lookup("64:ff9b::1.1.1.1") == .init(countryCode: "AU", provider: "Cloudflare"))
        #expect(database.metadata.dataDate == 20_261_009)
        #expect(database.metadata.countryCount == 6)
        #expect(database.metadata.providerCount == 5)
    }

    @Test func overlappingRangesAreRejected() {
        var builder = smallBuilder()
        builder.addPrefix("2a00:1450:4001::/48", countryCode: "DE", provider: "Google")   // inside 2a00:1450::/32
        #expect(throws: GeoIPDatabaseBuilder.BuildError.overlappingRanges) { try builder.build() }
    }

    @Test func emptyDatabaseIsValid() throws {
        let database = try GeoIPDatabase(data: GeoIPDatabaseBuilder().build())
        #expect(database.lookup(.v4(0x0808_0808)) == .init())
        #expect(database.lookup(try #require(IPAddress("2606::1"))) == .init())
        #expect(database.metadata.ipv4EntryCount == 0)
    }

    @Test func builderRejectsBadInput() {
        var builder = GeoIPDatabaseBuilder()
        builder.addIPv4(first: 1, last: 5, countryCode: "de", provider: nil)
        #expect(throws: GeoIPDatabaseBuilder.BuildError.invalidCountryCode("de")) { try builder.build() }
        var overlapping = GeoIPDatabaseBuilder()
        overlapping.addIPv4(first: 1, last: 5, countryCode: "DE", provider: nil)
        overlapping.addIPv4(first: 5, last: 9, countryCode: "FR", provider: nil)
        #expect(throws: GeoIPDatabaseBuilder.BuildError.overlappingRanges) { try overlapping.build() }
        var longPrefix = GeoIPDatabaseBuilder()
        let tooLong = longPrefix.addPrefix("2001:db8::/64", countryCode: "DE", provider: nil)
        let badLength = longPrefix.addPrefix("1.2.3.0/33", countryCode: "DE", provider: nil)
        let nonsense = longPrefix.addPrefix("nonsense", countryCode: "DE", provider: nil)
        #expect(!tooLong && !badLength && !nonsense)
    }

    @Test func corruptDataIsRejectedNeverCrashes() throws {
        let good = try smallDatabase()
        #expect(throws: GeoIPDatabaseError.self) { try GeoIPDatabase(data: Data()) }
        #expect(throws: GeoIPDatabaseError.badMagic) {
            var bad = good; bad[0] = UInt8(ascii: "X"); return try GeoIPDatabase(data: bad)
        }
        #expect(throws: GeoIPDatabaseError.unsupportedVersion(2)) {
            var bad = good; bad[5] = 2; return try GeoIPDatabase(data: bad)
        }
        // Every truncation fails validation.
        for length in stride(from: 0, to: good.count, by: 97) {
            #expect((try? GeoIPDatabase(data: good.prefix(length))) == nil, "truncated to \(length)")
        }
        #expect((try? GeoIPDatabase(data: good + [0])) == nil)
        // Flipping any single byte either fails validation or yields a database whose lookups still work.
        var survivors = 0
        for index in 0..<good.count {
            var mutated = good
            mutated[index] ^= 0xFF
            if let database = try? GeoIPDatabase(data: mutated) {
                survivors += 1
                for text in ["17.1.2.3", "1.1.1.1", "255.255.255.255", "0.0.0.0", "80.5.5.5", "2606:4700::1", "ffff::1", "::"] {
                    _ = database.lookup(try #require(IPAddress(text)))
                }
            }
        }
        // Most single-byte changes break an invariant; the few that survive are payload changes
        // (an index that still points inside the tables, the date stamp, a name's letters).
        #expect(survivors < good.count / 2)
    }

    @Test func classifierTreatsCorruptDataAsNoData() throws {
        var bad = try smallDatabase()
        bad.removeLast(10)
        let classifier = DestinationClassifier(geoData: bad)
        #expect(!classifier.hasGeoData)
        let info = classifier.info(forAddress: "17.1.2.3", port: 443, transport: .tcp)
        #expect(info == DestinationInfo(scope: .internet, countryCode: nil, provider: nil, service: "HTTPS"))
    }

    /// The database shipped in the app (made by scripts/build-geoip.py) loads and answers for
    /// addresses whose owners are certain. Skipped (as a failure) only if the file is missing.
    @Test func shippedDatabaseLoads() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PulseDeck/Resources/GeoIP.bin")
        let data = try Data(contentsOf: url)
        #expect(data.count <= 3_000_000)
        let database = try GeoIPDatabase(data: data)
        #expect(database.metadata.ipv4EntryCount > 0)
        let apple = database.lookup(try #require(IPAddress("17.253.144.10")))
        #expect(apple.provider == "Apple")
        #expect(apple.countryCode == "US")
        #expect(database.lookup(try #require(IPAddress("1.1.1.1"))).provider == "Cloudflare")
        #expect(database.lookup(try #require(IPAddress("8.8.8.8"))).provider == "Google")
        #expect(database.lookup(try #require(IPAddress("140.82.112.3"))).provider == "GitHub")
        #expect(database.lookup(try #require(IPAddress("2606:4700:4700::1111"))).provider == "Cloudflare")
        #expect(database.lookup(try #require(IPAddress("2a00:1450:4001:81b::200e"))).provider == "Google")
        // A residential-range address has a country but no allow-listed provider.
        #expect(database.lookup(try #require(IPAddress("2.16.0.1"))).countryCode != nil)
        // Private space is not in the database.
        #expect(database.lookup(try #require(IPAddress("192.168.1.1"))) == .init())
    }
}

// MARK: - Classifier, ports, host names

@Suite("Destination classifier")
struct DestinationClassifierTests {
    @Test func scopeCountryProviderService() throws {
        let classifier = DestinationClassifier(geoData: try smallDatabase())
        #expect(classifier.hasGeoData)
        #expect(classifier.info(forAddress: "17.253.144.10", port: 5223, transport: .tcp)
            == DestinationInfo(scope: .internet, countryCode: "US", provider: "Apple", service: "Apple Push Notification Service"))
        // 443 to Apple is not refined.
        #expect(classifier.info(forAddress: "17.253.144.10", port: 443, transport: .tcp).service == "HTTPS")
        #expect(classifier.info(forAddress: "17.253.144.10", port: 443, transport: .udp).service == "QUIC (HTTP/3)")
        // Port 5223 elsewhere is XMPP over TLS.
        #expect(classifier.info(forAddress: "1.1.1.1", port: 5223, transport: .tcp).service == "XMPP (TLS)")
        #expect(classifier.info(forAddress: "192.168.1.20", port: 548, transport: .tcp)
            == DestinationInfo(scope: .localNetwork, countryCode: nil, provider: nil, service: "AFP"))
        #expect(classifier.info(forAddress: "100.101.102.103", port: 41_641, transport: .udp).scope == .tailscale)
        #expect(classifier.info(forAddress: "::ffff:17.1.1.1", port: 80, transport: .tcp).provider == "Apple")
        #expect(classifier.info(forAddress: "not-an-ip", port: 80, transport: .tcp) == DestinationInfo(scope: .unspecified))
        // Non-internet scopes never get geo data, even if the database were to cover them.
        #expect(classifier.info(forAddress: "10.0.0.1", port: 0, transport: .tcp).countryCode == nil)
    }

    @Test func withoutDataOnlyBuiltInTables() {
        let classifier = DestinationClassifier()
        #expect(!classifier.hasGeoData)
        #expect(classifier.info(forAddress: "8.8.8.8", port: 53, transport: .udp)
            == DestinationInfo(scope: .internet, countryCode: nil, provider: nil, service: "DNS"))
        #expect(classifier.info(forAddress: "8.8.8.8", port: 0, transport: .other(1)).service == "ICMP")
        #expect(classifier.info(forAddress: "8.8.8.8", port: 0, transport: .other(47)).service == nil)
    }

    @Test func wellKnownPorts() {
        let expectations: [(FlowTransport, UInt16, String?)] = [
            (.tcp, 443, "HTTPS"), (.udp, 443, "QUIC (HTTP/3)"), (.tcp, 80, "HTTP"), (.tcp, 53, "DNS"), (.udp, 53, "DNS"),
            (.tcp, 853, "DNS over TLS"), (.udp, 123, "NTP"), (.tcp, 22, "SSH"), (.tcp, 25, "SMTP"), (.tcp, 465, "SMTPS"),
            (.tcp, 587, "SMTP (submission)"), (.tcp, 993, "IMAPS"), (.tcp, 143, "IMAP"), (.tcp, 110, "POP3"), (.tcp, 995, "POP3S"),
            (.udp, 5353, "mDNS (Bonjour)"), (.udp, 1900, "SSDP"), (.udp, 3478, "STUN/TURN"), (.udp, 19_302, "STUN/TURN"),
            (.tcp, 3389, "RDP"), (.tcp, 5900, "VNC"), (.tcp, 445, "SMB"), (.tcp, 548, "AFP"), (.tcp, 631, "IPP printing"),
            (.tcp, 8080, "HTTP (alt)"), (.tcp, 8443, "HTTPS (alt)"), (.udp, 51_820, "WireGuard"), (.udp, 41_641, "Tailscale"),
            (.tcp, 5060, "SIP"), (.tcp, 5061, "SIP (TLS)"), (.tcp, 6379, "Redis"), (.tcp, 5432, "PostgreSQL"), (.tcp, 3306, "MySQL"),
            (.tcp, 27_017, "MongoDB"), (.tcp, 9418, "Git"), (.tcp, 2049, "NFS"),
            // Transport matters: syslog is UDP only, 514/tcp is not claimed.
            (.udp, 514, "Syslog"), (.tcp, 514, nil), (.tcp, 123, nil), (.tcp, 0, nil), (.udp, 1, nil), (.tcp, 54_321, nil),
        ]
        for (transport, port, expected) in expectations {
            #expect(PortServices.name(transport: transport, port: port) == expected, "\(transport.name)/\(port)")
        }
    }

    @Test func hostNameSuffixes() {
        let expectations: [(String, String?)] = [
            ("rr3---sn-4g5e6nsy.googlevideo.com", "YouTube"),
            ("www.youtube.com", "YouTube"),
            ("fra15s18-in-f14.1e100.net", "Google"),
            ("server-13-35-1-1.fra56.r.cloudfront.net", "Amazon CloudFront"),
            ("ec2-1-2-3-4.compute-1.amazonaws.com", "Amazon Web Services"),
            ("a23-1-2-3.deploy.static.akamaitechnologies.com", "Akamai"),
            ("e1.akamaiedge.net", "Akamai"),
            ("edge-star-mini-shv-01-fra3.facebook.com", "Meta"),
            ("scontent-fra3-1.xx.fbcdn.net", "Meta"),
            ("ipv4-c001-fra001-ix.1.oca.nflxvideo.net", "Netflix"),
            ("lb-140-82-112-3-fra.github.com", "GitHub"),
            ("wss-primary.slack-edge.com", "Slack"),
            ("us02web.zoom.us", "Zoom"),
            ("17-253-144-10.icloud.com", "iCloud"),
            ("courier.push.apple.com", "Apple Push Notification Service"),
            ("gsp-ssl.ls.apple.com", "Apple"),
            ("teams.microsoft.com", "Microsoft Teams"),
            ("www.microsoft.com", "Microsoft"),
            ("myapp.azurewebsites.net", "Microsoft Azure"),
            ("blob.core.windows.net", "Microsoft Azure"),
            ("151.101.1.69.fastly.net", "Fastly"),
            ("one.one.one.one", "Cloudflare"),
            ("gateway.discord.gg", "Discord"),
            ("audio-ak-spotify-com.akamaized.net", "Akamai"),
            ("spclient.wg.spotify.com", "Spotify"),
            ("video-weaver.fra02.hls.ttvnw.net", "Twitch"),
            ("cdn.steamstatic.com", "Steam"),
            ("host.tail1234.ts.net", "Tailscale"),
            ("WWW.GITHUB.COM.", "GitHub"),
            ("notgithub.com", nil),
            ("github.com.evil.example", nil),
            ("example.org", nil),
            ("", nil),
            (".", nil),
        ]
        for (name, expected) in expectations {
            #expect(DestinationClassifier.service(forHostName: name) == expected, "\(name)")
        }
    }
}

// MARK: - Grouping

private func makeDestination(
    _ address: String, received: UInt64, sent: UInt64, active: Int = 0, rx: Double? = nil, tx: Double? = nil,
    ports: [PortTotals] = [], processes: [ProcessTotals] = []
) -> DestinationTotals {
    DestinationTotals(
        address: address, family: address.contains(":") ? .v6 : .v4, bytesReceived: received, bytesSent: sent,
        flowCount: ports.reduce(0) { $0 + $1.flowCount }, activeFlowCount: active,
        firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 100),
        receiveBytesPerSecond: rx, sendBytesPerSecond: tx, ports: ports, processes: processes)
}

private func groupingFixture() -> [DestinationTotals] {
    [
        makeDestination("17.253.1.1", received: 1_000, sent: 100, active: 2, rx: 100, tx: 10,
                        ports: [PortTotals(transport: .tcp, port: 5223, bytesReceived: 900, bytesSent: 90, flowCount: 2),
                                PortTotals(transport: .tcp, port: 443, bytesReceived: 100, bytesSent: 10, flowCount: 1)],
                        processes: [ProcessTotals(processName: "apsd", bytesReceived: 900, bytesSent: 90),
                                    ProcessTotals(processName: "Safari", bytesReceived: 100, bytesSent: 10)]),
        makeDestination("80.1.1.1", received: 200, sent: 50, active: 1, rx: 20, tx: 5,
                        ports: [PortTotals(transport: .tcp, port: 22, bytesReceived: 200, bytesSent: 50, flowCount: 1)],
                        processes: [ProcessTotals(processName: "ssh", bytesReceived: 200, bytesSent: 50)]),
        makeDestination("93.184.216.34", received: 80, sent: 35, active: 1, rx: 8, tx: 3,
                        ports: [PortTotals(transport: .tcp, port: 80, bytesReceived: 70, bytesSent: 30, flowCount: 1),
                                PortTotals(transport: .tcp, port: 443, bytesReceived: 10, bytesSent: 5, flowCount: 1)],
                        processes: [ProcessTotals(processName: "curl", bytesReceived: 80, bytesSent: 35)]),
        makeDestination("192.168.1.5", received: 10, sent: 10,
                        ports: [PortTotals(transport: .udp, port: 5353, bytesReceived: 10, bytesSent: 10, flowCount: 1)]),
        makeDestination("8.8.8.8", received: 30, sent: 0),   // no breakdown at all, not in the database
        makeDestination("142.250.1.1", received: 5_000, sent: 500, active: 3, rx: 500, tx: 50,
                        ports: [PortTotals(transport: .udp, port: 443, bytesReceived: 5_000, bytesSent: 500, flowCount: 3)],
                        processes: [ProcessTotals(processName: "Safari", bytesReceived: 4_000, bytesSent: 400)]),   // 1000/100 unexplained
    ]
}

private func groupingClassifier() throws -> DestinationClassifier {
    var builder = GeoIPDatabaseBuilder()
    builder.addPrefix("17.0.0.0/8", countryCode: "US", provider: "Apple")
    builder.addPrefix("142.250.0.0/15", countryCode: "US", provider: "Google")
    builder.addPrefix("80.0.0.0/8", countryCode: "DE", provider: "Deutsche Telekom")
    builder.addPrefix("93.184.216.0/24", countryCode: "FR", provider: nil)
    return DestinationClassifier(geoData: try builder.build())
}

private let groupingHostNames = ["142.250.1.1": "rr1---sn-x.googlevideo.com", "80.1.1.1": "dtag.example.net"]

private func total(_ groups: [FlowGroup]) -> (received: UInt64, sent: UInt64) {
    (groups.reduce(0) { $0 + $1.bytesReceived }, groups.reduce(0) { $0 + $1.bytesSent })
}

@Suite("Flow grouping")
struct FlowGrouperTests {
    let destinations = groupingFixture()
    let fixtureReceived: UInt64 = 1_000 + 200 + 80 + 10 + 30 + 5_000
    let fixtureSent: UInt64 = 100 + 50 + 35 + 10 + 0 + 500

    private func groups(_ grouping: FlowGrouping, input: [DestinationTotals]? = nil) throws -> [FlowGroup] {
        FlowGrouper.group(input ?? destinations, by: grouping, classifier: try groupingClassifier(), hostNames: groupingHostNames)
    }

    @Test(arguments: FlowGrouping.allCases)
    func totalsAreConservedAndSorted(grouping: FlowGrouping) throws {
        let result = try groups(grouping)
        let sums = total(result)
        #expect(sums.received == fixtureReceived)
        #expect(sums.sent == fixtureSent)
        #expect(zip(result, result.dropFirst()).allSatisfy { $0.totalBytes >= $1.totalBytes })
        #expect(Set(result.map(\.id)).count == result.count)
        for group in result {
            #expect(group.destinations.map(\.totalBytes) == group.destinations.map(\.totalBytes).sorted(by: >))
            #expect(group.destinationCount == group.destinations.count)
            #expect(group.destinations.reduce(0) { $0 + $1.bytesReceived } == group.bytesReceived)
        }
        // Deterministic: input order does not matter.
        let reversed = try groups(grouping, input: destinations.reversed())
        #expect(reversed == result)
    }

    @Test func byDestinationUsesHostNames() throws {
        let result = try groups(.destination)
        #expect(result.count == 6)
        #expect(result.first?.id == "142.250.1.1")
        #expect(result.first?.title == "rr1---sn-x.googlevideo.com")
        #expect(result.first { $0.id == "8.8.8.8" }?.title == "8.8.8.8")
        #expect(result.first?.receiveBytesPerSecond == 500)
        #expect(result.first?.activeFlowCount == 3)
    }

    @Test func byCountry() throws {
        let result = try groups(.country)
        let titles = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.title) })
        #expect(titles["US"] == "United States")
        #expect(titles["DE"] == "Germany")
        #expect(titles["FR"] == "France")
        #expect(titles["local-network"] == "Local network")
        #expect(titles[FlowGroup.unknownKey] == "Unknown")
        let us = try #require(result.first { $0.id == "US" })
        #expect(us.destinationCount == 2)
        #expect(us.bytesReceived == 6_000)
        #expect(us.activeFlowCount == 5)
        #expect(us.receiveBytesPerSecond == 600)
        #expect(result.first?.id == "US")
        #expect(try #require(result.first { $0.id == FlowGroup.unknownKey }).destinations.map(\.address) == ["8.8.8.8"])
    }

    @Test func byProvider() throws {
        let result = try groups(.provider)
        let ids = Set(result.map(\.id))
        #expect(ids == ["Google", "Apple", "Deutsche Telekom", "local-network", FlowGroup.unknownKey])
        // 93.184.216.0/24 has a country but no provider: it is "Unknown" together with 8.8.8.8.
        let unknown = try #require(result.first { $0.id == FlowGroup.unknownKey })
        #expect(Set(unknown.destinations.map(\.address)) == ["8.8.8.8", "93.184.216.34"])
    }

    @Test func byService() throws {
        let result = try groups(.service)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        // The host-name brand replaces the generic "QUIC (HTTP/3)".
        #expect(byID["YouTube"]?.destinations.map(\.address) == ["142.250.1.1"])
        #expect(byID["Apple Push Notification Service"]?.destinations.map(\.address) == ["17.253.1.1"])
        #expect(byID["SSH"] != nil)
        #expect(byID["HTTP"]?.destinations.map(\.address) == ["93.184.216.34"])   // dominant port is 80
        #expect(byID["mDNS (Bonjour)"] != nil)
        #expect(byID[FlowGroup.unknownKey]?.destinations.map(\.address) == ["8.8.8.8"])
    }

    @Test func serviceFallsBackToHostNameWhenPortIsUnknown() {
        let odd = makeDestination("8.8.4.4", received: 5, sent: 5,
                                  ports: [PortTotals(transport: .tcp, port: 54_321, bytesReceived: 5, bytesSent: 5, flowCount: 1)])
        let result = FlowGrouper.group([odd], by: .service, classifier: DestinationClassifier(),
                                       hostNames: ["8.8.4.4": "dns.google"])
        #expect(result.map(\.id) == ["Google DNS"])
    }

    @Test func byProcessAttributesBytesAndSplitsDestinations() throws {
        let result = try groups(.process)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let safari = try #require(byID["Safari"])
        #expect(safari.bytesReceived == 100 + 4_000)
        #expect(safari.bytesSent == 10 + 400)
        #expect(safari.destinationCount == 2)   // 17.253.1.1 and 142.250.1.1
        #expect(byID["apsd"]?.bytesReceived == 900)
        #expect(byID["curl"]?.bytesSent == 35)
        // Unexplained bytes: 142.250.1.1's 1000/100 remainder, all of 192.168.1.5 and 8.8.8.8.
        let unknown = try #require(byID[FlowGroup.unknownKey])
        #expect(unknown.bytesReceived == 1_000 + 10 + 30)
        #expect(unknown.bytesSent == 100 + 10)
        #expect(Set(unknown.destinations.map(\.address)) == ["142.250.1.1", "192.168.1.5", "8.8.8.8"])
        // The member carries only that process's share; rates are split by share, flows counted once.
        let apple = try #require(byID["apsd"]?.destinations.first)
        #expect(apple.processes == [ProcessTotals(processName: "apsd", bytesReceived: 900, bytesSent: 90)])
        #expect(abs((apple.receiveBytesPerSecond ?? 0) - 90) < 1e-9)
        // Safari: 100 of 1000 bytes at 17.253.1.1 (rate 100 → 10) and 4000 of 5000 at 142.250.1.1 (500 → 400).
        #expect(abs(safari.receiveBytesPerSecond - 410) < 1e-9)
        let activeFlows: Int = result.map(\.activeFlowCount).reduce(0, +)
        #expect(activeFlows == 7)   // 2 + 1 + 1 + 3: each destination's active flows are counted once
    }

    @Test func byPortAttributesBytesPerPortAndPicksTitleByTransport() throws {
        let result = try groups(.port)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let https = try #require(byID["443"])
        // QUIC (UDP) carries most of the bytes on 443 here.
        #expect(https.title == "443 · QUIC (HTTP/3)")
        #expect(https.destinationCount == 3)
        #expect(https.bytesReceived == 100 + 10 + 5_000)
        #expect(byID["5223"]?.title == "5223 · XMPP (TLS)")
        #expect(byID["22"]?.title == "22 · SSH")
        #expect(byID["5353"]?.title == "5353 · mDNS (Bonjour)")
        #expect(byID["80"]?.bytesSent == 30)
        // 8.8.8.8 has no ports.
        #expect(byID[FlowGroup.unknownKey]?.destinations.map(\.address) == ["8.8.8.8"])
        #expect(FlowGrouper.portTitle(54_321) == "54321")
        #expect(FlowGrouper.portTitle(0) == "No port")
    }

    @Test func byTransportProtocol() throws {
        let result = try groups(.transportProtocol)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let tcp = try #require(byID["TCP"])
        let udp = try #require(byID["UDP"])
        let expectedTCP: UInt64 = 900 + 100 + 200 + 80
        let expectedUDP: UInt64 = 10 + 5_000
        #expect(tcp.bytesReceived == expectedTCP)
        #expect(udp.bytesReceived == expectedUDP)
        #expect(tcp.title == "TCP")
        #expect(tcp.destinationCount == 3)
        #expect(byID[FlowGroup.unknownKey]?.destinations.map(\.address) == ["8.8.8.8"])
    }

    @Test func emptyInputGivesNoGroups() throws {
        for grouping in FlowGrouping.allCases {
            #expect(try groups(grouping, input: []).isEmpty)
        }
    }

    @Test func nonInternetScopesGetPseudoGroups() {
        let inputs = ["127.0.0.1": "loopback", "169.254.3.3": "link-local", "224.0.0.251": "multicast",
                      "100.64.1.1": "tailscale", "10.0.0.2": "local-network"]
        let destinations = inputs.keys.sorted().map { makeDestination($0, received: 1, sent: 1) }
        for grouping in [FlowGrouping.country, .provider] {
            let result = FlowGrouper.group(destinations, by: grouping, classifier: DestinationClassifier())
            #expect(Set(result.map(\.id)) == Set(inputs.values))
        }
        let titles = Set(FlowGrouper.group(destinations, by: .country, classifier: DestinationClassifier()).map(\.title))
        #expect(titles == ["This Mac (loopback)", "Link-local", "Multicast", "Tailscale", "Local network"])
    }
}
