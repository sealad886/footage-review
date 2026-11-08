#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

mode="${1:-all}"
case "$mode" in
    all|--backend-only) ;;
    *) fail "Usage: $0 [--backend-only]" ;;
esac
require_macos_tools
command -v git >/dev/null || fail "Git is required."
command -v uv >/dev/null || fail "Install uv first: https://docs.astral.sh/uv/getting-started/installation/"

# Reconcile an existing checkout before Git is allowed to update it.
if [[ -e "$clustering_repo/.git" ]]; then check_submodule; fi
git -C "$project_dir" submodule update --init --recursive
check_submodule

printf '%s\n' "Preparing the pinned clustering backend with Python 3.13…"
uv sync --directory "$clustering_repo/backend" --python 3.13 --locked
if [[ "$mode" == all ]]; then
    printf '%s\n' "Verifying or downloading the pinned local face models…"
    uv run --directory "$clustering_repo/backend" --locked --no-sync python -m app.models_setup
fi
printf '%s\n' "Setup complete. Build and open Footage Review with ./script/build_and_run.sh."
