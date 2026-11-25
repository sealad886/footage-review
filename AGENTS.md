# Footage Review contributor guidance

Footage Review is a macOS 26+ SwiftPM application using native Apple frameworks. Keep source, generated app bundles and private review libraries separate.

## Normal commands

```bash
./script/setup.sh
./script/check.sh --metadata
./script/check.sh
./script/build_and_run.sh --build-only
./script/check.sh --bundle
```

Use `./script/build_and_run.sh` to build and open the native app. It owns bundle metadata and ad-hoc signing; do not launch the raw SwiftPM executable as a normal GUI workflow. The script refuses to overwrite a running bundle. Pause active work and quit that exact app before rebuilding.

## Ownership and scope

- `Version.env` is the single marketing-version/build source. Follow [docs/RELEASING.md](docs/RELEASING.md); do not add another bump writer or treat build numbers as publication.
- `External/cluster-grouper` is an independently maintained Git submodule. Keep its recorded commit. Make upstream changes in that project and update the pin deliberately; do not silently edit or replace it during native UI work.
- Extend the canonical `ReviewStore`, API router and clustering coordinator rather than introducing parallel stores or import paths.
- Preserve existing user changes. Do not create worktrees, discard changes, commit, push, tag, publish or change remote settings without the applicable explicit authorization.
- If a `.codegraph` index exists, use it before text search for code understanding. Do not create an index implicitly.

## Data and verification

- Never add source videos, library JSON, crop images, embeddings, credentials, `.env`, local databases, generated bundles or backup directories to Git. Keep `.build/`, `dist/` and libraries private.
- Ignore `.DS_Store` during discovery and processing; preserve the files.
- Use temporary libraries and public/synthetic fixtures for automated or GUI testing. Do not initiate scans or imports against an operator's library as an incidental verification step.
- Maintain pause/cancel/resume, complete group membership, immutable import IDs/revisions and same-request replay. Clustering suggestions require human approval and explicit import.
- Run tests that prove the changed behavior. Distinguish source/build evidence, signed bundle identity, runtime observations and operator acceptance. Never claim recognition accuracy from synthetic or same-face fixtures.
- Settings/contract tests are always local. Managed recovery tests need the prepared backend and models; the positive model/import test additionally needs explicitly supplied public-sample assets.

The app is a source-checkout build. Its default clustering backend path comes from the generated bundle metadata or SwiftPM source-root fallback. Keep the checkout available and rebuild after moving it.

## Issues and pull requests

Create and resolve issues to coordinate work across chats and teams. A pull request can stand on its own. Link and resolve related issues when applicable. When creating a GitHub issue, set the applicable available issue fields. When planning from an issue, review its fields, description, and comments.

## Code search

Run `codanna mcp -h` to find the indexed code and documentation search interface.
