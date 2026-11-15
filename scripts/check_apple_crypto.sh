#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stage=$(mktemp -d /tmp/lanlink-crypto.XXXXXX)
trap 'rm -rf "$stage"' EXIT
cp scripts/check_apple_crypto.swift "$stage/main.swift"
xcrun swiftc apple/Shared/DirectPeerEngine.swift apple/Shared/QuickNativeSender.swift "$stage/main.swift" -o "$stage/check"
"$stage/check" test/fixtures/apple_quick_crypto.json "$@"
