#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
identity="${LANLINK_MACOS_SIGNING_IDENTITY:?Set LANLINK_MACOS_SIGNING_IDENTITY to a valid Apple Development certificate SHA-1}"
team_id="${LANLINK_MACOS_TEAM_ID:?Set LANLINK_MACOS_TEAM_ID to its Apple team ID}"
output_dir="${LANLINK_MACOS_OUTPUT_DIR:-$repo_root/build/macos-signed/dist}"
derived_data="$repo_root/build/macos-signed/DerivedData"
flutter_bin="${FLUTTER_BIN:-flutter}"

if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "LANLINK_MACOS_SIGNING_IDENTITY must be a certificate SHA-1." >&2
  exit 1
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "LANLINK_MACOS_TEAM_ID must be a 10-character Apple team ID." >&2
  exit 1
fi
identity_listing="$(security find-identity -p codesigning -v)"
if [[ "$identity_listing" != *"$identity"* ]]; then
  echo "The requested signing identity is not available in this Mac's keychain." >&2
  exit 1
fi

cd "$repo_root"
"$flutter_bin" pub get
"$flutter_bin" build macos --release --config-only
xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  "CODE_SIGN_IDENTITY=$identity" \
  "DEVELOPMENT_TEAM=$team_id" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=YES \
  build -quiet

source_app="$derived_data/Build/Products/Release/lanlink.app"
test -d "$source_app"
mkdir -p "$output_dir"
archive="$output_dir/LanLink-macOS-signed.zip"
if [[ -e "$archive" ]]; then
  echo "Refusing to overwrite $archive" >&2
  exit 1
fi
stage_dir="$(mktemp -d /tmp/lanlink-macos-signed.XXXXXX)"
trap 'rm -rf -- "$stage_dir"' EXIT
staged_app="$stage_dir/lanlink.app"
# Cloud-backed folders can add Finder/resource-fork metadata to signed bundles.
ditto --norsrc "$source_app" "$staged_app"
xattr -cr "$staged_app"
codesign --verify --deep --strict "$staged_app"

signature_info="$(codesign -dv --verbose=4 "$staged_app" 2>&1)"
[[ "$signature_info" == *"TeamIdentifier=$team_id"* ]] || {
  echo "The signed app has an unexpected team ID." >&2
  exit 1
}
[[ "$signature_info" == *"Identifier=com.example.lanlink"* ]] || {
  echo "The signed app has an unexpected bundle ID." >&2
  exit 1
}
ditto -c -k --keepParent "$staged_app" "$archive"
mkdir "$stage_dir/extracted"
ditto -x -k "$archive" "$stage_dir/extracted"
codesign --verify --deep --strict "$stage_dir/extracted/lanlink.app"
printf 'Signed archive: %s\n' "$archive"
printf '%s\n' "$signature_info" | awk '/Identifier=|Authority=|TeamIdentifier=/'
