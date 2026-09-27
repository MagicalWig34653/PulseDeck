#!/usr/bin/env bash
# Installs a Swift 6.2 toolchain in a Linux container (e.g. a Claude Code cloud session) so the
# platform-independent package code (PulseDeckCore) can be built and tested without a Mac.
# The macOS-only code (PulseDeckTelemetry, the SwiftUI app) is compiled out on Linux and must be
# verified by the macOS CI workflow.
#
# Usage:  source <(scripts/setup-linux-swift.sh /path/to/toolchain-dir)
#   then: cd PulseDeckKit && swift test --build-path "$SWIFT_TOOLCHAIN_DIR/build" \
#           -Xlinker -L"$SWIFT_TOOLCHAIN_DIR/stub"
#
# Why each step exists:
# - swift.org downloads are blocked by the cloud egress proxy, but archive.ubuntu.com works and
#   carries Debian-packaged Swift (swiftlang) built for newer Ubuntu releases.
# - That build links against libxml2.so.16, which Ubuntu 24.04 lacks; the library is fetched
#   from the same archive (it only needs glibc 2.38).
# - The package ships Testing.swiftmodule but not lib_Testing_Foundation.so, which the test
#   runner links whenever Foundation and Testing are both imported. An empty stub library
#   satisfies the linker (the overlay's symbols are not used by these tests).
# Everything is extracted into the given directory; nothing is installed system-wide.
set -euo pipefail

dir="${1:?usage: $0 <toolchain-dir>}"
mkdir -p "$dir"
cd "$dir"

swift_version="6.2.3-1"
xml_version="2.15.2+dfsg-0.1"
pool="http://archive.ubuntu.com/ubuntu/pool"

if [[ ! -x swift/usr/libexec/swift/bin/swift ]]; then
    for package in "swiftlang_${swift_version}_amd64" "libswiftlang_${swift_version}_amd64"; do
        curl -sSf -O "$pool/universe/s/swiftlang/$package.deb" >&2
        dpkg-deb -x "$package.deb" swift
        rm -f "$package.deb"
    done
fi

if [[ ! -e xml/usr/lib/x86_64-linux-gnu/libxml2.so.16 ]]; then
    curl -sSf -O "$pool/main/libx/libxml2/libxml2-16_${xml_version}_amd64.deb" >&2
    dpkg-deb -x "libxml2-16_${xml_version}_amd64.deb" xml
    rm -f "libxml2-16_${xml_version}_amd64.deb"
fi

if [[ ! -e stub/lib_Testing_Foundation.so ]]; then
    mkdir -p stub
    : > stub/empty.c
    PATH="$dir/swift/usr/libexec/swift/bin:$PATH" \
        LD_LIBRARY_PATH="$dir/xml/usr/lib/x86_64-linux-gnu" \
        clang -shared -o stub/lib_Testing_Foundation.so stub/empty.c
fi

# Printed so the caller can `source` it.
cat <<EOF
export SWIFT_TOOLCHAIN_DIR="$dir"
export PATH="$dir/swift/usr/libexec/swift/bin:\$PATH"
export LD_LIBRARY_PATH="$dir/xml/usr/lib/x86_64-linux-gnu:$dir/stub"
EOF
