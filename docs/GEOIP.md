# GeoIP data (Traffic section)

The Traffic section groups a Mac's network destinations by country, provider and service **offline**: no
address is ever sent to a lookup service. Three layers (all in `PulseDeckCore/NetworkFlows/`):

| Layer | Source | Code |
|---|---|---|
| Scope (loopback, LAN, link-local, multicast, Tailscale …) | IANA special-purpose address registries | `AddressScopeClassifier` |
| Country and provider | `PulseDeck/Resources/GeoIP.bin` | `GeoIPDatabase`, produced by `scripts/build-geoip.py` |
| Service | well-known port table (IANA registry plus a few de-facto ports), host-name suffix table | `PortServices`, `HostNameServices` |

Unknown stays unknown: an address outside the database has no country and no provider, and the UI shows
"Unknown" rather than a guess. A missing or corrupt `GeoIP.bin` behaves exactly like an empty one.

## What the shipped file contains (built 2026-10-09)

| | |
|---|---|
| Size | 2,645,558 bytes (limit: 3 MB) |
| IPv4 | 337,266 entries (ranges, explicit gaps, and bucket splits); 72.6 % of the 32-bit space has a country |
| IPv6 | 136,531 entries, keyed by the top 48 bits (/48) |
| Countries | 240 |
| Providers | 66 (list below); about 21 % of the IPv4 space carries a provider |
| Source data date | 2026-10-09 |

Providers: 1&1 Versatel, A1 Telekom Austria, AT&T, Akamai, Akamai Connected Cloud (Linode), Alibaba Cloud,
Amazon AWS, Amazon CloudFront, Apple, BT, Blizzard, Charter / Spectrum, China Mobile, China Telecom, China
Unicom, Cisco Umbrella, Cloudflare, Comcast, Contabo, Deutsche Telekom, DigitalOcean, Dropbox, Fastly,
Fly.io, Free (France), GitHub, Google, Google Cloud, Google Fiber, Hetzner, Huawei Cloud, IBM Cloud,
IONOS / 1&1, KPN, Leaseweb, Liberty Global, LinkedIn, Magenta Telekom, Meta, Microsoft, Netflix, O2 /
Telefonica Germany, OVHcloud, Oracle, Orange, Rackspace, Riot Games, Salesforce, Scaleway, Squarespace,
Starlink, Swisscom, T-Mobile US, Telefonica Spain, Tencent, TikTok (ByteDance), VK, Valve (Steam),
Verizon, Vodafone, Vultr, Wikimedia, X (Twitter), Yandex, Zoom, Zscaler.

### Known limits

- **Country is the registration country of the network operator** (IPtoASN: the country of the origin AS),
  not the physical location of the server. A Google or Cloudflare address in Frankfurt is reported as
  "United States", and anycast addresses have a single country. Treat it as "whose network", not "where".
- **Provider is the origin AS, not the service.** Microsoft includes Azure; Google is separate from Google
  Cloud only where Google uses separate AS numbers; Amazon AWS includes Amazon's retail services except the
  CloudFront ranges, which Amazon publishes and which are labelled "Amazon CloudFront". Content that
  providers serve from third-party networks (for example a CDN cache inside an ISP) shows the host network.
- Addresses that are allocated but not announced in BGP have no entry (IPtoASN is derived from BGP), so
  they are "Unknown". Private, loopback and multicast space is
  never in the file; it is classified by scope.
- IPv6 uses /48 granularity, the longest prefix that is routed publicly. Longer prefixes in the sources
  (a few hundred) were skipped.
- Providers are a curated allow-list (`PROVIDERS` in `scripts/build-geoip.py`, keyed by AS number). Adding
  one is a one-line change; AS numbers must be checked against `--list-providers`. Four AS numbers could not
  be verified by name in the data (`AS2906` Netflix, `AS6805` Telefonica Germany, `AS5511` Orange
  OpenTransit, `AS12322` Free) and rest on the operators' public registrations.

## Sources, licences, attribution

All data is bundled in an AGPL-3.0 app; none of these licences prevents that.

| Source | Used for | Licence |
|---|---|---|
| IPtoASN, https://iptoasn.com, as republished in `sapics/ip-location-db` releases (`iptoasn-country-ipv4/ipv6.csv`, `iptoasn-asn-ipv4/ipv6.csv`) | address range → country of the origin AS; address range → origin AS number and organisation | Public Domain Dedication and License (PDDL 1.0), as listed in the ip-location-db README. Attribution is not required but is given. |
| Amazon `ip-ranges.json`, https://ip-ranges.amazonaws.com/ip-ranges.json | the `CLOUDFRONT` ranges, to label Amazon CloudFront | Published by AWS for exactly this purpose (allow-listing); it carries no explicit open licence. Only the factual address ranges are used. Build with `--without-cloudfront` to leave it out. |
| IANA special-purpose address registries; IANA Service Name and Transport Protocol Port Number Registry | scope table; port → service table | Public domain (IANA registries). |

The attribution text for About / Settings is `PulseDeck/Resources/GeoIP-NOTICE.txt`.

Other sources considered and **not** used: MaxMind GeoLite2 (MaxMind's own EULA) and DB-IP Lite (CC BY 4.0;
attribution-only, but PDDL data was preferred), and the operators' own range files for Google, Cloudflare,
Microsoft and GitHub (their hosts were not reachable from the build environment; the AS-based data covers
the same networks).

## Regenerating

```sh
python3 scripts/build-geoip.py                 # downloads the sources, writes PulseDeck/Resources/GeoIP.bin
python3 scripts/build-geoip.py --cache-dir /tmp/geoip          # keep the downloads
python3 scripts/build-geoip.py --cache-dir /tmp/geoip --offline  # rebuild from the cache, no network
python3 scripts/build-geoip.py --list-providers                # AS numbers → names in the data, for review
python3 scripts/build-geoip.py --empty                         # valid database without ranges (2 KB)
```

Python 3.9+, standard library only. The output is deterministic for identical inputs (no timestamps; the
embedded data date is the sources' `Last-Modified` date), runs in about ten seconds, and fails if the file
exceeds 3 MB or the self-check addresses (17.253.144.10 → Apple, 1.1.1.1 → Cloudflare, 8.8.8.8 → Google)
resolve wrongly. The test `FlowClassificationTests/shippedDatabaseLoads` loads the committed file from the
repository path and checks known addresses. Rebuild roughly monthly; the app does not update the file by itself.

## File format (version 1)

Written by `scripts/build-geoip.py` and, for tests, by `GeoIPDatabaseBuilder`; read by `GeoIPDatabase`
(which documents the same layout at the top of `GeoIPDatabase.swift`). **All integers are big-endian**, there
is no padding, and sections follow each other in the order below.

```
Header, 48 bytes
   0  4  magic "PDGI"
   4  2  format version = 1
   6  2  header size = 48
   8  4  data date YYYYMMDD
  12  4  IPv4 entry count
  16  4  IPv6 entry count
  20  2  country table entries (>= 1, entry 0 = unknown)
  22  2  provider table entries (>= 1, entry 0 = unknown)
  24  1  IPv6 key bytes (6 = top 48 bits)
  25  3  zero
  28  4  country table offset (48)
  32  4  provider table offset
  36  4  IPv4 section offset
  40  4  IPv6 section offset
  44  4  file size
Country table      countryCount x 2 ASCII bytes; entry 0 = 00 00
Provider table     (providerCount + 1) x UInt32 end offsets (offset[0] = 0 = offset[1]), then UTF-8 blob;
                   provider i = blob[offset[i] ..< offset[i+1]]; provider 0 is empty
Address section (IPv4: 4-byte keys; IPv6: 6-byte keys), `count` entries
   257 x UInt32   bucket index; bucket b (top key byte) = entries index[b] ..< index[b+1]
   count x (keyBytes-1)   low key bytes (key without its top byte), strictly increasing within a bucket
   count x UInt8  country index
   count x UInt8  provider index
```

An entry covers its key up to the next entry's key; the last entry runs to the end of the address space.
Gaps are explicit entries with country 0 and provider 0. For a non-empty section every bucket is non-empty
and starts at low key 0 (the builders repeat the covering entry at bucket boundaries), so a lookup is one
bucket-index read and one binary search.

`GeoIPDatabase(data:)` validates the whole file once (magic, version, every offset and size, contiguity,
table contents, bucket index monotonicity, key ordering, index ranges) and throws on any violation, so a
corrupt or truncated file never reaches a lookup; `DestinationClassifier` then simply has no geo data.
