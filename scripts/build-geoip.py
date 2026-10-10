#!/usr/bin/env python3
"""Builds PulseDeck/Resources/GeoIP.bin, the offline IP -> (country, provider) database.

Standard library only (Python 3.9+). The output is deterministic: the same inputs always give the
same bytes (no timestamps from the clock, sorted tables). Usage:

    python3 scripts/build-geoip.py                       # download sources, write PulseDeck/Resources/GeoIP.bin
    python3 scripts/build-geoip.py --cache-dir DIR       # keep / reuse the downloaded files
    python3 scripts/build-geoip.py --offline --cache-dir DIR   # no network, use the cache only
    python3 scripts/build-geoip.py --empty               # valid database without any ranges

Sources (see docs/GEOIP.md for licences and attribution):
  * IPtoASN via the sapics/ip-location-db release files "iptoasn-country-ipv4/ipv6.csv" and
    "iptoasn-asn-ipv4/ipv6.csv" (PDDL 1.0): address range -> country of the origin AS, and
    address range -> origin AS number + organisation.
  * Amazon's published ip-ranges.json: the CLOUDFRONT ranges refine "Amazon AWS" to
    "Amazon CloudFront".

Providers: only a curated allow-list of well-known networks (PROVIDERS below, keyed by AS number)
is kept; every other range carries only its country. IPv6 is stored as 48-bit prefixes (the longest
prefix that is routed on the public internet); longer prefixes are skipped.

The binary format is documented at the top of PulseDeckKit/Sources/PulseDeckCore/NetworkFlows/GeoIPDatabase.swift
and in docs/GEOIP.md; GeoIPDatabaseBuilder.swift writes the same format for tests.
"""

import argparse
import bisect
import csv
import datetime
import email.utils
import ipaddress
import json
import os
import re
import ssl
import struct
import sys
import tempfile
import urllib.request

# --------------------------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------------------------

# The release URL is assembled so this file stays easy to grep for hosts.
IP_LOCATION_DB = "https://github.com/sapics/ip-location-db/releases/download/latest/"
SOURCE_FILES = {
    "country4": IP_LOCATION_DB + "iptoasn-country-ipv4.csv",
    "country6": IP_LOCATION_DB + "iptoasn-country-ipv6.csv",
    "asn4": IP_LOCATION_DB + "iptoasn-asn-ipv4.csv",
    "asn6": IP_LOCATION_DB + "iptoasn-asn-ipv6.csv",
    "aws": "https://ip-ranges.amazonaws.com/ip-ranges.json",
}

# Provider allow-list: display name -> origin AS numbers. Every AS number was checked against the
# organisation name in the IPtoASN data (see --list-providers). A new provider needs a name that is
# short and recognisable to a Mac user, and AS numbers that belong to that organisation only.
PROVIDERS = {
    "Apple": [714, 6185],
    "Google": [15169, 36040, 43515, 19527, 36384, 36385, 36492, 395973, 16550, 139070, 139190, 45566, 41264],
    "Google Cloud": [396982, 32381],
    "Google Fiber": [16591],
    "Cloudflare": [13335, 14789, 132892, 202623, 203898, 209242, 394536, 395747, 139242],
    "Amazon AWS": [16509, 14618, 8987, 7224],
    "Microsoft": [8075, 8068, 8069, 8070, 3598, 5761, 6584, 12076, 45139, 58862, 35106],
    "Meta": [32934, 54115, 63293],
    "Akamai": [12222, 16625, 20940, 21342, 24319, 31108, 33905, 34164, 35994, 36183, 17204, 26008],
    "Akamai Connected Cloud (Linode)": [63949],
    "Fastly": [54113, 394192],
    "Netflix": [40027, 2906],
    "GitHub": [36459],
    "DigitalOcean": [14061, 393406],
    "Hetzner": [24940, 212317, 213230, 215859],
    "OVHcloud": [16276, 35540],
    "Oracle": [31898],
    "Alibaba Cloud": [37963, 45102, 134963],
    "Tencent": [45090, 132203, 133478],
    "Huawei Cloud": [136907],
    "Vultr": [20473],
    "Leaseweb": [60781],
    "Contabo": [51167],
    "Scaleway": [12876],
    "IBM Cloud": [36351],
    "Rackspace": [19994],
    "Fly.io": [40509],
    "Squarespace": [53831],
    "Deutsche Telekom": [3320],
    "Vodafone": [3209, 1273],
    "O2 / Telefonica Germany": [6805],
    "IONOS / 1&1": [8560],
    "1&1 Versatel": [8881],
    "Liberty Global": [6830],
    "Comcast": [7922],
    "AT&T": [7018, 20057],
    "Verizon": [701, 6167],
    "Charter / Spectrum": [20115, 7843, 11426],
    "T-Mobile US": [21928],
    "BT": [2856],
    "Orange": [3215, 5511],
    "Free (France)": [12322],
    "Telefonica Spain": [3352],
    "Swisscom": [3303],
    "KPN": [1136],
    "A1 Telekom Austria": [8447],
    "Magenta Telekom": [8412],
    "China Telecom": [4134],
    "China Unicom": [4837],
    "China Mobile": [9808],
    "Yandex": [13238],
    "VK": [47541],
    "Valve (Steam)": [32590],
    "Riot Games": [6507],
    "Blizzard": [57976],
    "Zoom": [30103],
    "Salesforce": [14340],
    "Dropbox": [19679],
    "Starlink": [14593],
    "Zscaler": [22616, 62044],
    "Cisco Umbrella": [36692],
    "X (Twitter)": [13414],
    "LinkedIn": [13443],
    "TikTok (ByteDance)": [396986, 138699],
    "Wikimedia": [14907],
}

# Ranges published by the operators themselves that the AS data cannot express.
#  * Apple owns 17.0.0.0/8 (ARIN: "APPLE-WWNET"); AS714/AS6185 announce it, this is a safety net.
STATIC_PROVIDER_RANGES = [
    ("17.0.0.0/8", "Apple"),
]

AWS_CLOUDFRONT_PROVIDER = "Amazon CloudFront"

MAX_V4 = (1 << 32) - 1
V6_KEY_BITS = 48
V6_SHIFT = 128 - V6_KEY_BITS
MAX_V6_KEY = (1 << V6_KEY_BITS) - 1
V6_KEY_BYTES = V6_KEY_BITS // 8

MAGIC = b"PDGI"
FORMAT_VERSION = 1
HEADER_SIZE = 48
BUCKETS = 256  # entries are indexed by the top byte of the key
MAX_TABLE_ENTRIES = 255  # indices are one byte; 0 is "unknown"
SIZE_LIMIT = 3 * 1024 * 1024


# --------------------------------------------------------------------------------------------
# Download
# --------------------------------------------------------------------------------------------

def fetch(name, url, cache_dir, offline):
    """Returns (bytes, last_modified_date or None); the cache keeps the body and a .meta file."""
    body_path = os.path.join(cache_dir, name)
    meta_path = body_path + ".meta"
    if offline and os.path.exists(body_path):
        meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
        return open(body_path, "rb").read(), meta.get("last_modified")
    if offline:
        sys.exit("--offline: %s is not in the cache directory %s" % (name, cache_dir))
    context = ssl.create_default_context()  # verifies certificates; honours SSL_CERT_FILE
    request = urllib.request.Request(url, headers={"User-Agent": "PulseDeck-build-geoip/1"})
    with urllib.request.urlopen(request, timeout=300, context=context) as response:
        body = response.read()
        modified = response.headers.get("Last-Modified")
    stamp = None
    if modified:
        stamp = email.utils.parsedate_to_datetime(modified).strftime("%Y-%m-%d")
    os.makedirs(cache_dir, exist_ok=True)
    open(body_path, "wb").write(body)
    json.dump({"last_modified": stamp, "url": url}, open(meta_path, "w"))
    return body, stamp


# --------------------------------------------------------------------------------------------
# Interval helpers. A "range list" is a sorted list of (first, last, value) with inclusive ends.
# --------------------------------------------------------------------------------------------

def v6_keys(first, last):
    """Converts a 128-bit inclusive range to the 48-bit prefix keys it fully covers, or None."""
    low_mask = (1 << V6_SHIFT) - 1
    first_key = first >> V6_SHIFT if first & low_mask == 0 else (first >> V6_SHIFT) + 1
    last_key = last >> V6_SHIFT if last & low_mask == low_mask else (last >> V6_SHIFT) - 1
    if first_key > last_key:
        return None
    return first_key, last_key


def parse_ranges(text, family, value_column):
    """Parses 'start,end,value[,more]' rows into (first, last, value) in key space."""
    result = []
    skipped = 0
    for row in csv.reader(text.splitlines()):
        if len(row) <= value_column:
            continue
        try:
            first = int(ipaddress.ip_address(row[0].strip()))
            last = int(ipaddress.ip_address(row[1].strip()))
        except ValueError:
            continue
        value = row[value_column].strip()
        if family == 6:
            keys = v6_keys(first, last)
            if keys is None:
                skipped += 1
                continue
            first, last = keys
        result.append((first, last, value))
    result.sort(key=lambda item: item[0])
    return result, skipped


def merge_layers(layers):
    """Overlays several sorted, non-overlapping range lists.

    Returns [(first, last, (value_layer0, value_layer1, ...))] covering every address that at least one
    layer covers; uncovered layers contribute None. Overlapping ranges inside one layer are an error
    in the source data and abort the build.
    """
    for index, layer in enumerate(layers):
        for previous, current in zip(layer, layer[1:]):
            if current[0] <= previous[1]:
                sys.exit("layer %d has overlapping ranges: %r and %r" % (index, previous, current))
    boundaries = set()
    for layer in layers:
        for first, last, _ in layer:
            boundaries.add(first)
            boundaries.add(last + 1)
    ordered = sorted(boundaries)
    positions = [0] * len(layers)
    result = []
    for lo, hi in zip(ordered, ordered[1:]):
        values = []
        for index, layer in enumerate(layers):
            position = positions[index]
            while position < len(layer) and layer[position][1] < lo:
                position += 1
            positions[index] = position
            if position < len(layer) and layer[position][0] <= lo:
                values.append(layer[position][2])
            else:
                values.append(None)
        if any(value is not None for value in values):
            result.append((lo, hi - 1, tuple(values)))
    return result


def collapse_overlapping(ranges):
    """Merges overlapping/duplicate ranges that carry the same value (used for published lists)."""
    ranges = sorted(ranges, key=lambda item: (item[0], item[1]))
    result = []
    for first, last, value in ranges:
        if result and first <= result[-1][1] + 1 and result[-1][2] == value:
            result[-1] = (result[-1][0], max(result[-1][1], last), value)
        else:
            result.append((first, last, value))
    return result


# --------------------------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------------------------

def build_family(country_ranges, asn_ranges, overlays, as_provider):
    """Returns a sorted list of (first, last, country or None, provider or None), adjacent-merged."""
    # asn_ranges values are AS number strings; only allow-listed ASes become a provider layer.
    asn_provider = [(first, last, as_provider.get(int(value))) for first, last, value in asn_ranges]
    provider_layer = [(f, l, p) for f, l, p in asn_provider if p is not None]
    country_layer = [(f, l, c) for f, l, c in country_ranges if re.fullmatch(r"[A-Z]{2}", c)]
    layers = [country_layer, provider_layer]
    layers.extend(overlays)
    merged = merge_layers(layers)
    segments = []
    for first, last, values in merged:
        country = values[0]
        provider = values[1]
        for override in values[2:]:
            if override is not None:
                provider = override
        if country is None and provider is None:
            continue
        if segments and segments[-1][1] + 1 == first and segments[-1][2] == country and segments[-1][3] == provider:
            segments[-1] = (segments[-1][0], last, country, provider)
        else:
            segments.append((first, last, country, provider))
    return segments


def overlay_layer(prefixes, family, provider):
    ranges = []
    skipped = 0
    for prefix in prefixes:
        network = ipaddress.ip_network(prefix, strict=False)
        first, last = int(network.network_address), int(network.broadcast_address)
        if family == 6:
            keys = v6_keys(first, last)
            if keys is None:
                skipped += 1
                continue
            first, last = keys
        ranges.append((first, last, provider))
    return collapse_overlapping(ranges), skipped


# --------------------------------------------------------------------------------------------
# Binary writer (format version 1, big-endian; see GeoIPDatabase.swift)
# --------------------------------------------------------------------------------------------

def with_gaps(segments, max_key):
    """Turns segments into start-keyed entries (start, country, provider) with explicit gap entries
    (country None, provider None) so that every key up to max_key maps to exactly one entry. No
    segments at all gives no entries (an empty section)."""
    entries = []
    cursor = 0
    for first, last, country, provider in segments:
        if first > cursor:
            entries.append((cursor, None, None))
        entries.append((first, country, provider))
        cursor = last + 1
    if entries and cursor <= max_key:
        entries.append((cursor, None, None))
    return entries


def split_at_buckets(entries, key_bytes):
    """Guarantees that every bucket (top key byte) of a non-empty section starts with an entry at low
    key 0, by repeating the covering entry at each bucket boundary. Lookups then never leave a bucket."""
    if not entries:
        return []
    shift = 8 * (key_bytes - 1)
    result = []
    position = 0
    for bucket in range(BUCKETS):
        boundary = bucket << shift
        while position + 1 < len(entries) and entries[position + 1][0] <= boundary:
            position += 1
        if entries[position][0] != boundary:
            result.append((boundary,) + entries[position][1:])
        # entries that start inside this bucket
        scan = position
        while scan < len(entries) and entries[scan][0] < boundary + (1 << shift):
            if entries[scan][0] >= boundary:
                result.append(entries[scan])
            scan += 1
    return result


def write_database(v4_segments, v6_segments, date_stamp):
    v4 = with_gaps(v4_segments, MAX_V4)
    v6 = with_gaps(v6_segments, MAX_V6_KEY)
    countries = sorted({c for _, c, _ in v4 + v6 if c})
    providers = sorted({p for _, _, p in v4 + v6 if p})
    if len(countries) + 1 > MAX_TABLE_ENTRIES or len(providers) + 1 > MAX_TABLE_ENTRIES:
        sys.exit("too many countries/providers for one-byte indices")
    country_index = {code: i + 1 for i, code in enumerate(countries)}
    provider_index = {name: i + 1 for i, name in enumerate(providers)}

    country_table = b"\0\0" + b"".join(code.encode("ascii") for code in countries)
    names = [b""] + [name.encode("utf-8") for name in providers]
    offsets = [0]
    for name in names:
        offsets.append(offsets[-1] + len(name))
    # offsets[i]..offsets[i+1] is name i; there are len(names)+1 offsets.
    provider_table = b"".join(struct.pack(">I", o) for o in offsets) + b"".join(names)

    def section(entries, key_bytes):
        """bucket index (257 x u32) + low keys + countries + providers; see GeoIPDatabase.swift."""
        entries = split_at_buckets(entries, key_bytes)
        shift = 8 * (key_bytes - 1)
        low_mask = (1 << shift) - 1
        index = [0] * (BUCKETS + 1)
        for start, _, _ in entries:
            index[(start >> shift) + 1] += 1
        for bucket in range(BUCKETS):
            index[bucket + 1] += index[bucket]
        table = b"".join(struct.pack(">I", i) for i in index)
        lows = b"".join((start & low_mask).to_bytes(key_bytes - 1, "big") for start, _, _ in entries)
        cs = bytes(country_index.get(c, 0) for _, c, _ in entries)
        ps = bytes(provider_index.get(p, 0) for _, _, p in entries)
        return table + lows + cs + ps, len(entries)

    v4_section, v4_count = section(v4, 4)
    v6_section, v6_count = section(v6, V6_KEY_BYTES)
    country_offset = HEADER_SIZE
    provider_offset = country_offset + len(country_table)
    v4_offset = provider_offset + len(provider_table)
    v6_offset = v4_offset + len(v4_section)
    file_size = v6_offset + len(v6_section)
    header = (MAGIC
              + struct.pack(">HHIIIHH", FORMAT_VERSION, HEADER_SIZE, date_stamp, v4_count, v6_count,
                            len(countries) + 1, len(providers) + 1)
              + bytes([V6_KEY_BYTES, 0, 0, 0])
              + struct.pack(">IIIII", country_offset, provider_offset, v4_offset, v6_offset, file_size))
    assert len(header) == HEADER_SIZE, len(header)
    blob = header + country_table + provider_table + v4_section + v6_section
    assert len(blob) == file_size
    return blob, v4, v6, countries, providers


def lookup(entries, key):
    starts = [e[0] for e in entries]
    index = bisect.bisect_right(starts, key) - 1
    return entries[index][1:] if index >= 0 else (None, None)


def v4_key(text):
    return int(ipaddress.IPv4Address(text))


def v6_key(text):
    return int(ipaddress.IPv6Address(text)) >> V6_SHIFT


# --------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", default=None, help="default: PulseDeck/Resources/GeoIP.bin next to this script's repo")
    parser.add_argument("--cache-dir", default=os.path.join(tempfile.gettempdir(), "pulsedeck-geoip"))
    parser.add_argument("--offline", action="store_true", help="use only files already in --cache-dir")
    parser.add_argument("--empty", action="store_true", help="write a valid database without ranges")
    parser.add_argument("--without-cloudfront", action="store_true",
                        help="skip Amazon's ip-ranges.json (CloudFront refinement); Amazon addresses stay 'Amazon AWS'")
    parser.add_argument("--list-providers", action="store_true", help="print the organisation name of every allow-listed AS and exit")
    args = parser.parse_args()

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output = args.output or os.path.join(repo, "PulseDeck", "Resources", "GeoIP.bin")

    as_provider = {}
    for name, numbers in PROVIDERS.items():
        for number in numbers:
            if number in as_provider:
                sys.exit("AS%d listed twice" % number)
            as_provider[number] = name

    if args.empty:
        blob, v4, v6, countries, providers = write_database([], [], 0)
        os.makedirs(os.path.dirname(output), exist_ok=True)
        open(output, "wb").write(blob)
        print("wrote empty database,", len(blob), "bytes")
        return

    raw = {}
    dates = {}
    for key, url in SOURCE_FILES.items():
        if key == "aws" and args.without_cloudfront:
            continue
        raw[key], dates[key] = fetch(key, url, args.cache_dir, args.offline)
        print("fetched %-9s %9d bytes  last-modified %s" % (key, len(raw[key]), dates[key]), file=sys.stderr)

    country4, skipped_c4 = parse_ranges(raw["country4"].decode("utf-8"), 4, 2)
    country6, skipped_c6 = parse_ranges(raw["country6"].decode("utf-8"), 6, 2)
    asn4, _ = parse_ranges(raw["asn4"].decode("utf-8"), 4, 2)
    asn6, skipped_a6 = parse_ranges(raw["asn6"].decode("utf-8"), 6, 2)

    if args.list_providers:
        names = {}
        for text in (raw["asn4"], raw["asn6"]):
            for row in csv.reader(text.decode("utf-8").splitlines()):
                names[int(row[2])] = row[3]
        for number, name in sorted(as_provider.items(), key=lambda kv: (kv[1], kv[0])):
            print("%-34s AS%-7d %s" % (name, number, names.get(number, "-- not in data --")))
        return

    # Overlays: static ranges and CloudFront.
    static4 = collapse_overlapping([(int(n.network_address), int(n.broadcast_address), provider)
                                    for n, provider in ((ipaddress.ip_network(p), prov) for p, prov in STATIC_PROVIDER_RANGES)
                                    if n.version == 4])
    aws = {}
    cf4, cf6, skipped_cf6 = [], [], 0
    if "aws" in raw:
        aws = json.loads(raw["aws"].decode("utf-8"))
        cf4, _ = overlay_layer([p["ip_prefix"] for p in aws["prefixes"] if p["service"] == "CLOUDFRONT"], 4, AWS_CLOUDFRONT_PROVIDER)
        cf6, skipped_cf6 = overlay_layer([p["ipv6_prefix"] for p in aws["ipv6_prefixes"] if p["service"] == "CLOUDFRONT"], 6, AWS_CLOUDFRONT_PROVIDER)

    # Priority: CloudFront > AS data > static safety-net ranges (which only fill in a missing provider).
    seg4 = build_family(country4, asn4, [cf4] if cf4 else [], as_provider)
    seg6 = build_family(country6, asn6, [cf6] if cf6 else [], as_provider)
    seg4 = apply_static(seg4, static4)

    sources = [dates.get(k) for k in ("country4", "country6", "asn4", "asn6") if dates.get(k)]
    stamp = max(sources) if sources else "1970-01-01"
    date_stamp = int(stamp.replace("-", ""))
    blob, v4, v6, countries, providers = write_database(seg4, seg6, date_stamp)

    if len(blob) > SIZE_LIMIT:
        sys.exit("database is %d bytes, over the %d byte limit" % (len(blob), SIZE_LIMIT))

    # Self-check against well-known addresses (fails loudly if data or format went wrong).
    checks = [
        ("17.253.144.10", 4, "US", "Apple"),
        ("1.1.1.1", 4, None, "Cloudflare"),
        ("8.8.8.8", 4, "US", "Google"),
    ]
    for text, family, country, provider in checks:
        got_country, got_provider = lookup(v4, v4_key(text)) if family == 4 else lookup(v6, v6_key(text))
        if (country and got_country != country) or got_provider != provider:
            sys.exit("self-check failed for %s: got %s/%s" % (text, got_country, got_provider))

    os.makedirs(os.path.dirname(output), exist_ok=True)
    open(output, "wb").write(blob)
    v4_total, v6_total = struct.unpack(">II", blob[12:20])
    print("wrote %s: %d bytes, %d IPv4 entries, %d IPv6 entries, %d countries, %d providers, source date %s"
          % (output, len(blob), v4_total, v6_total, len(countries), len(providers), stamp))
    print("skipped (longer than /%d or unaligned): country6=%d asn6=%d cloudfront6=%d"
          % (V6_KEY_BITS, skipped_c6, skipped_a6, skipped_cf6), file=sys.stderr)
    print("source dates: %s" % json.dumps(dates, sort_keys=True), file=sys.stderr)
    print("aws syncToken %s createDate %s" % (aws.get("syncToken"), aws.get("createDate")), file=sys.stderr)


def apply_static(segments, static_ranges):
    """Gives `provider` to the parts of segments inside static_ranges that have no provider."""
    layers = [[(f, l, (c, p)) for f, l, c, p in segments], static_ranges]
    merged = merge_layers(layers)
    result = []
    for first, last, (base, static) in merged:
        country, provider = base if base is not None else (None, None)
        if provider is None and static is not None:
            provider = static
        if country is None and provider is None:
            continue
        if result and result[-1][1] + 1 == first and result[-1][2] == country and result[-1][3] == provider:
            result[-1] = (result[-1][0], last, country, provider)
        else:
            result.append((first, last, country, provider))
    return result


if __name__ == "__main__":
    main()
