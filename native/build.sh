#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$source_dir")"
output="${OPENTALON_NATIVE_OUTPUT:-/Volumes/Expand/Codex Media/opentalon/native}"
configuration="${OPENTALON_NATIVE_CONFIGURATION:-release}"
signing="${OPENTALON_NATIVE_SIGNING:-developer-id}"
notarize="${OPENTALON_NATIVE_NOTARIZE:-0}"
bundle_version="${OPENTALON_NATIVE_BUILD_NUMBER:-}"
update_feed="${OPENTALON_NATIVE_UPDATE_FEED:-}"
icloud_profile="${OPENTALON_NATIVE_ICLOUD_PROFILE:-}"
previous_profile="$output/OpenTalon.app/Contents/embedded.provisionprofile"
if [[ -z "$icloud_profile" && "$signing" == developer-id && -f "$previous_profile" ]]; then
  icloud_profile="$previous_profile"
fi
version=25.9.0
arch="$(uname -m)"
case "$arch" in
  arm64) runtime_arch=arm64; checksum=e479f3c469d3d9303a44f00a8ea37a3788395d171bb8059c48a4bbbd2e371b59 ;;
  *) echo "This local build script currently packages Apple Silicon." >&2; exit 1 ;;
esac
if [[ "$output" == /Volumes/Expand/* && ! -d /Volumes/Expand ]]; then
  echo "Mount Expand before building." >&2
  exit 1
fi
case "$signing" in
  developer-id)
    keychain="${CSC_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
    identity="${CSC_NAME:-Developer ID Application: Protomota, LLC (22HV69L32T)}"
    if [[ ! -f "$keychain" || "$keychain" == /Library/Keychains/System.keychain ]]; then
      echo "Select your login or dedicated user signing keychain. See docs/SIGNING.md." >&2
      exit 1
    fi
    identities="$(/usr/bin/security find-identity -v -p codesigning "$keychain")"
    fingerprint="$(awk -v identity="$identity" 'index($0, "\"" identity "\"") && !/CSSMERR_/ { print $2; exit }' <<< "$identities")"
    if [[ -z "$fingerprint" ]]; then
      echo "Developer ID signing identity not found in $keychain. See docs/SIGNING.md." >&2
      exit 1
    fi
    signature=(--sign "$fingerprint" --keychain "$keychain" --timestamp --options runtime)
    node_signature=("${signature[@]}" --entitlements "$repo/build/entitlements.mac.plist")
    ;;
  adhoc)
    signature=(--sign -)
    node_signature=("${signature[@]}")
    ;;
  *)
    echo "Use developer-id or adhoc for OPENTALON_NATIVE_SIGNING." >&2
    exit 1
    ;;
esac
if [[ "$notarize" == 1 && ( "$signing" != developer-id || ! -f "${APPLE_API_KEY:-}" ||
    -z "${APPLE_API_KEY_ID:-}" || -z "${APPLE_API_ISSUER:-}" ) ]]; then
  echo "Notarization requires Developer ID and the App Store Connect API credentials. See docs/SIGNING.md." >&2
  exit 1
fi
command -v magick >/dev/null || { echo "ImageMagick is required to prepare the app artwork." >&2; exit 1; }
mkdir -p "$output"/{runtime,tmp,cache,build}
export TMPDIR="$output/tmp"
export CLANG_MODULE_CACHE_PATH="$output/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/cache/swift"
runtime="node-v$version-darwin-$runtime_arch"
archive="$output/runtime/$runtime.tar.gz"
if [[ ! -f "$archive" ]]; then
  curl --fail --silent --show-error --location --max-time 120 \
    "https://nodejs.org/dist/v$version/$runtime.tar.gz" -o "$archive.partial"
  mv "$archive.partial" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$output/runtime" "$runtime/bin/node" "$runtime/LICENSE"

swift build --package-path "$source_dir" --scratch-path "$output/build" \
  --cache-path "$output/cache" --disable-dependency-cache -c "$configuration"
binary_dir="$(swift build --package-path "$source_dir" --scratch-path "$output/build" \
  --cache-path "$output/cache" --disable-dependency-cache -c "$configuration" --show-bin-path)"
staging="$(mktemp -d "$output/.bundle.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/OpenTalon.app"
contents="$bundle/Contents"
resources="$contents/Resources"
mkdir -p "$contents/Library/LaunchAgents" "$contents/MacOS" "$contents/Helpers" "$resources/service" "$resources/assets"
install -m 755 "$binary_dir/OpenTalon" "$contents/MacOS/OpenTalon"
install -m 755 "$output/runtime/$runtime/bin/node" "$contents/Helpers/node"
install -m 644 "$output/runtime/$runtime/LICENSE" "$resources/Node-LICENSE"
install -m 644 "$source_dir/Info.plist" "$contents/Info.plist"
if [[ -n "$bundle_version" ]]; then
  [[ "$bundle_version" =~ ^[1-9][0-9]*$ ]] || { echo "Use a positive Mac build number." >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set CFBundleVersion $bundle_version" "$contents/Info.plist"
fi
if [[ "$signing" == adhoc ]]; then
  /usr/libexec/PlistBuddy -c "Delete SUFeedURL" "$contents/Info.plist"
elif [[ -n "$update_feed" ]]; then
  /usr/libexec/PlistBuddy -c "Set SUFeedURL $update_feed" "$contents/Info.plist"
fi
sparkle="$(find "$output/build/artifacts" -type d -path '*/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
if [[ -z "$sparkle" ]]; then
  echo "The resolved Sparkle framework was not found." >&2
  exit 1
fi
framework="$contents/Frameworks/Sparkle.framework"
mkdir -p "$contents/Frameworks"
/usr/bin/ditto "$sparkle" "$framework"
install -m 644 "$repo/assets/opentalon.icns" "$resources/opentalon.icns"
install -m 644 "$source_dir/assets/opentalon-logo-1024.png" "$resources/assets/opentalon-logo-1024.png"
install -m 644 "$repo/assets/claude-mark.png" "$repo/assets/openai-mark.png" "$resources/"
magick "$repo/assets/protomota-logo.png" -resize 88x88 "$resources/protomota-logo.png"
magick "$repo/assets/opentalon-wordmark.png" -resize 720x "$resources/wordmark.png"
for module in store contracts comments mcp mcp-bridge mcp-extension agent-readiness agent-runner agent-setup; do
  install -m 644 "$source_dir/runtime/$module.cjs" "$resources/service/$module.cjs"
done
for module in service daily-backup backup-once; do
  install -m 644 "$source_dir/$module.cjs" "$resources/service/$module.cjs"
done
install -m 644 "$source_dir/com.protomota.opentalon.native.daily-backup.plist" "$contents/Library/LaunchAgents/"

/usr/bin/codesign --force "${node_signature[@]}" "$contents/Helpers/node"
for helper in Autoupdate Updater.app XPCServices/Downloader.xpc XPCServices/Installer.xpc; do
  /usr/bin/codesign --force "${signature[@]}" "$framework/Versions/Current/$helper"
done
/usr/bin/codesign --force "${signature[@]}" "$framework"
if [[ -n "$icloud_profile" ]]; then
  if [[ "$signing" != developer-id ]]; then
    echo "Use Developer ID signing with the OpenTalon iCloud provisioning profile." >&2
    exit 1
  fi
  install -m 644 "$icloud_profile" "$contents/embedded.provisionprofile"
  signature+=(--entitlements "${OPENTALON_NATIVE_ICLOUD_ENTITLEMENTS:-$source_dir/CloudKit.entitlements}")
fi
/usr/bin/codesign --force "${signature[@]}" "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
if [[ "$notarize" == 1 ]]; then
  /usr/bin/ditto -c -k --keepParent "$bundle" "$staging/OpenTalon.zip"
  xcrun notarytool submit "$staging/OpenTalon.zip" --key "$APPLE_API_KEY" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait --timeout 20m \
    --output-format json | tee "$staging/notarization.json"
  status="$(/usr/bin/plutil -extract status raw -o - "$staging/notarization.json")"
  if [[ "$status" != Accepted ]]; then
    echo "Apple notarization did not succeed ($status)." >&2
    exit 1
  fi
  xcrun stapler staple "$bundle"
  xcrun stapler validate "$bundle"
  /usr/bin/codesign --verify --deep --strict "$bundle"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$bundle"
fi
# Swap only a previously built artifact under this output directory.
if [[ -e "$output/OpenTalon.app" ]]; then
  mv "$output/OpenTalon.app" "$staging/previous.app"
  if ! mv "$bundle" "$output/OpenTalon.app"; then
    mv "$staging/previous.app" "$output/OpenTalon.app"
    exit 1
  fi
else
  mv "$bundle" "$output/OpenTalon.app"
fi
if [[ "$notarize" == 1 ]]; then
  install -m 644 "$staging/notarization.json" "$output/notarization.json"
fi
printf 'Built %s\n' "$output/OpenTalon.app"
