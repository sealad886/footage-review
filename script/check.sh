#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mode="${1:-test}"
case "$mode" in
    test|--metadata|--bundle) ;;
    *) fail "Usage: $0 [--metadata|--bundle]" ;;
esac
require_macos_tools
read_version
check_submodule
cd "$project_dir"
for file in script/*.sh Version.env; do bash -n "$file"; done
for file in Sources/FootageReview/Models/*.swift; do
    [[ -f "$file" ]] || fail "Native model source files are missing."
    if git check-ignore -q --no-index -- "$file"; then fail "A required Swift source is ignored: $file"; fi
done

if [[ "$mode" == --metadata ]]; then
    printf '%s\n' "Version $app_version ($app_build), shell syntax, native sources and pinned submodule verified."
    exit 0
fi
if [[ "$mode" == --bundle ]]; then
    bundle="$project_dir/dist/Footage Review $app_version.app"
    plist="$bundle/Contents/Info.plist"
    [[ -f "$plist" ]] || fail "Build the bundle first with ./script/build_and_run.sh --build-only."
    /usr/bin/plutil -lint "$plist"
    [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")" == "$app_version" ]] || fail "Bundle marketing version differs from Version.env."
    [[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$plist")" == "$app_build" ]] || fail "Bundle build differs from Version.env."
    [[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$plist")" == 26.0 ]] || fail "Unexpected bundle deployment target."
    [[ "$(/usr/bin/plutil -extract ClusterGrouperRepository raw -o - "$plist")" == "$clustering_repo" ]] || fail "Bundle points at another clustering checkout."
    [[ ! -e "$bundle/Contents/Resources/SeedInventory.json" ]] || fail "The bundle contains an obsolete seed inventory."
    /usr/bin/codesign --verify --deep --strict "$bundle"
    printf '%s\n' "Bundle version, source-checkout dependency and signature verified."
    exit 0
fi

python="$clustering_repo/backend/.venv/bin/python"
[[ -x "$python" ]] || fail "Prepare the pinned backend with ./script/setup.sh first."
(
    cd "$clustering_repo/backend"
    "$python" - <<'PY'
from pathlib import Path
from app.models_setup import models_ready

ready, message = models_ready(Path('.models').resolve())
if not ready:
    raise SystemExit('Prepare the verified models with ./script/setup.sh first: ' + message)
PY
)
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/clang-module-cache"
test_args=(test)
if [[ "${FOOTAGE_REVIEW_DISABLE_PACKAGE_SANDBOX:-0}" == "1" ]]; then test_args+=(--disable-sandbox); fi
CLUSTER_NATIVE_E2E_REPOSITORY="$clustering_repo" swift "${test_args[@]}"
