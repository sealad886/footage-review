#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mode="${1:-run}"
case "$mode" in
    run|--build-only|--verify|--debug|--logs|--telemetry) ;;
    *) fail "Usage: $0 [--build-only|--verify|--debug|--logs|--telemetry]" ;;
esac
require_macos_tools
read_version
check_submodule
cd "$project_dir"
app_name="Footage Review"
executable="FootageReview"
bundle_id="local.footage.review"
bundle="$project_dir/dist/$app_name $app_version.app"
binary="$bundle/Contents/MacOS/$executable"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"

# Check the executable's inode, including a running process launched via a redirect.
binary_in_use() {
    [[ -f "$binary" ]] && /usr/sbin/lsof -a -d txt -t -- "$binary" >/dev/null 2>&1
}
if binary_in_use; then fail "Quit $app_name before rebuilding this bundle. Pause active work first."; fi

build_args=(-c release)
if [[ "${FOOTAGE_REVIEW_DISABLE_PACKAGE_SANDBOX:-0}" == "1" ]]; then build_args+=(--disable-sandbox); fi
swift build "${build_args[@]}"
build_dir="$(swift build "${build_args[@]}" --show-bin-path)"
mkdir -p "$project_dir/.build" "$project_dir/dist"
staging_dir="$(mktemp -d "$project_dir/.build/bundle.XXXXXX")"
trap 'if [[ -n "${staging_dir:-}" ]]; then /bin/rm -rf -- "$staging_dir"; fi' EXIT
staged_bundle="$staging_dir/$app_name $app_version.app"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
install -m 755 "$build_dir/$executable" "$staged_bundle/Contents/MacOS/$executable"
plist="$staged_bundle/Contents/Info.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>FootageReview</string>
  <key>CFBundleIdentifier</key><string>local.footage.review</string>
  <key>CFBundleName</key><string>Footage Review</string>
  <key>CFBundleDisplayName</key><string>Footage Review</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$app_version</string>
  <key>CFBundleVersion</key><string>$app_build</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict></plist>
PLIST
/usr/bin/plutil -insert ClusterGrouperRepository -string "$clustering_repo" "$plist"
/usr/bin/plutil -lint "$plist"
/usr/bin/codesign --force --sign - --timestamp=none "$staged_bundle"
/usr/bin/codesign --verify --deep --strict "$staged_bundle"

# Fresh staging excludes obsolete resources. Retain the replaced build privately.
if binary_in_use; then fail "The existing bundle opened during this build. Quit it and retry."; fi
if [[ -e "$bundle" ]]; then
    previous="$project_dir/.build/previous-bundles/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$previous"
    mv "$bundle" "$previous/"
fi
mv "$staged_bundle" "$bundle"
printf '%s\n' "$bundle"

case "$mode" in
    --build-only) ;;
    --debug) /usr/bin/lldb -- "$binary" ;;
    *) /usr/bin/open -n "$bundle" ;;
esac
case "$mode" in
    --verify)
        for _ in 1 2 3 4 5; do
            if binary_in_use; then exit 0; fi
            sleep 1
        done
        fail "The app process did not appear."
        ;;
    --logs) /usr/bin/log stream --style compact --predicate 'process == "FootageReview"' ;;
    --telemetry) /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\"" ;;
esac
