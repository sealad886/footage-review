#!/bin/bash

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
clustering_repo="$project_dir/External/cluster-grouper"

fail() { printf '%s\n' "$*" >&2; exit 1; }

require_macos_tools() {
    [[ "$(uname -s)" == Darwin ]] || fail "Footage Review requires macOS 26 or newer."
    local os_version swift_version
    os_version="$(/usr/bin/sw_vers -productVersion)"
    (( ${os_version%%.*} >= 26 )) || fail "Footage Review requires macOS 26 or newer (found $os_version)."
    command -v swift >/dev/null || fail "Install Xcode or its command-line tools with Swift 6.2 or newer."
    swift_version="$(swift --version)"
    if [[ "$swift_version" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]]; then
        (( BASH_REMATCH[1] > 6 || (BASH_REMATCH[1] == 6 && BASH_REMATCH[2] >= 2) )) \
            || fail "Swift 6.2 or newer is required."
    else
        fail "Could not determine the selected Swift compiler version."
    fi
}

read_version() {
    local key value
    app_version=""
    app_build=""
    [[ -f "$project_dir/Version.env" ]] || fail "Version.env is missing."
    while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
        case "$key" in
            ''|\#*) ;;
            APP_VERSION)
                [[ -z "$app_version" ]] || fail "APP_VERSION appears more than once."
                app_version="$value"
                ;;
            APP_BUILD)
                [[ -z "$app_build" ]] || fail "APP_BUILD appears more than once."
                app_build="$value"
                ;;
            *) fail "Unexpected entry in Version.env: $key" ;;
        esac
    done < "$project_dir/Version.env"
    [[ "$app_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
        || fail "APP_VERSION must contain three numeric components without leading zeroes."
    [[ "$app_build" =~ ^[1-9][0-9]{0,3}$ ]] \
        || fail "APP_BUILD must be an integer from 1 through 9999."
}

check_submodule() {
    command -v git >/dev/null || fail "Git is required."
    local pin actual
    pin="$(git -C "$project_dir" ls-files --stage -- External/cluster-grouper | awk '$1 == "160000" {print $2}')"
    [[ "$pin" =~ ^[0-9a-f]{40}$ ]] || fail "The Cluster Grouper submodule pin is missing. Clone this repository with Git."
    [[ -e "$clustering_repo/.git" ]] || fail "Initialize the submodule with ./script/setup.sh."
    actual="$(git -C "$clustering_repo" rev-parse HEAD)"
    [[ "$actual" == "$pin" ]] || fail "Cluster Grouper differs from the recorded submodule commit. Reconcile its work and pin deliberately."
    [[ -z "$(git -C "$clustering_repo" status --porcelain --untracked-files=normal)" ]] \
        || fail "Cluster Grouper has local changes. Preserve and reconcile them before setup or verification."
}
