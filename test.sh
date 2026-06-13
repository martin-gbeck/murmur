#!/bin/bash
# Run the test suite.
#
# With full Xcode installed, plain `swift test` works. With Command Line Tools
# only, the Swift Testing framework exists but SwiftPM does not add its search
# paths, so this script supplies them explicitly.
set -euo pipefail
cd "$(dirname "$0")"

if xcode-select -p 2>/dev/null | grep -qv CommandLineTools; then
    exec swift test "$@"
fi

CLT=/Library/Developer/CommandLineTools
FWORKS="$CLT/Library/Developer/Frameworks"
TLIB="$CLT/Library/Developer/usr/lib"
PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"

exec swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$FWORKS" \
    -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
    -Xlinker -F -Xlinker "$FWORKS" \
    -Xlinker -rpath -Xlinker "$FWORKS" \
    -Xlinker -rpath -Xlinker "$TLIB" \
    "$@"
