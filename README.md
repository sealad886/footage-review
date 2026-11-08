# Footage Review

Footage Review is a native macOS app for finding and reviewing face appearances in video. Import clips or a folder, scan selected footage with Apple Vision, inspect crops, play the source at the detection time, and organize appearances into reviewed groups.

**Cluster Faces** starts the app's local integration API and its own [Cluster Grouper](https://github.com/sealad886/cluster-grouper) backend, then exports detected appearances and starts local similarity clustering. Suggestions stay local until you review and explicitly import them. No browser server is needed for this workflow.

## Build and run

Requirements: macOS 26 or newer, Xcode or command-line tools providing Swift 6.2 or newer and the macOS 26 SDK, Git, and [uv](https://docs.astral.sh/uv/getting-started/installation/). CI uses uv 0.13.7. Setup prepares Python 3.13 in the clustering submodule's project environment; it may download that interpreter. It does not install global Python packages or require Node.js.

```bash
git clone --recurse-submodules https://github.com/sealad886/footage-review.git
cd footage-review
./script/setup.sh
./script/build_and_run.sh
```

Setup initializes the recorded submodule commit, installs its locked backend dependencies, and verifies or downloads the pinned YuNet and SFace model files. The build script creates and ad-hoc signs a real `.app` bundle under `dist/`, then opens it. Codex environment setup uses the same setup script; the Run button uses the same build entrypoint.

The app is built for the current Mac's architecture. Its clustering backend is supplied by the prepared source checkout under `External/cluster-grouper`; the bundle records that absolute location. Keep the checkout and environment available while using clustering. Moving the checkout requires rebuilding the bundle. This source build is not a self-contained portable application or a notarized installer.

Use `--build-only` to build without opening the app, or `--verify` to build, launch and verify the exact executable is running. The script refuses to replace a running copy of the same bundle. Quit it after pausing active work, then rebuild. Replaced bundles are retained privately under `.build/previous-bundles/`; the adjacent library is left in place.

On managed development hosts that reject SwiftPM's nested build sandbox, set `FOOTAGE_REVIEW_DISABLE_PACKAGE_SANDBOX=1` for the setup-independent build/check invocation. Normal builds retain SwiftPM sandboxing.

## Review footage

The app opens an empty library in a new checkout. **Import Clips** adds video files or recursively adds a folder. In **Clips**, filters narrow the scan by date, source, camera or filename; you can also select individual rows.

- **Scan Filtered** and **Scan Selected** queue the chosen scope.
- **Pause** saves the queue; **Resume** continues it after reopening the app.
- **Cancel** ends the queue while retaining completed receipts and groups.
- Completed clips save receipts and crops. A resumed scan adopts valid receipts; an interrupted clip is processed again from its beginning.

The scanner samples one frame per second and retains Apple Vision face detections with confidence at or above 0.5. Brief appearances and difficult faces may be missed. A detection is an appearance, not a confirmed identity.

In **Appearances**, double-click a crop to play its source at the saved frame offset. Use Command-click or Shift-click to select several appearances, then add them to a group. Names, notes and membership are saved in the library.

## Clustering and Settings

Click **Cluster Faces** in the toolbar or use **Clustering → Cluster Faces**. Footage Review starts its authenticated loopback API, launches an owned Python backend, connects without copying a token, exports detections and starts similarity suggestions. Pause, resume, cancel and review controls remain native. Completed results reopen; interrupted runs require explicit resume. Quitting pauses unfinished work and stops only the owned backend.

Open **Footage Review → Settings** with **⌘,**:

| Tab | Settings |
|---|---|
| General | Active library location and Finder access |
| Clustering | Tool checkout, model status, similarity threshold, minimum group size, exact date/source/camera scope and service controls |
| Integrations | Local API port, optional browser origin, manual start/stop and external client connection details |

The default tool folder is this checkout's pinned submodule. A manually selected valid checkout remains an explicit preference. Scope is independent of the main window's filters and defaults to all detected appearances. Existing reviewed groups are excluded from new suggestions. Changing scope or parameters applies to **Start New Clustering Run**, not a previously saved run.

Choose **Review Suggestions**, inspect every crop, correct membership and approve the groups to keep. **Prepare Import** saves an immutable request with the original revision and IDs; inspect it before explicitly importing. Retry an uncertain save with that same request. Each export supports at most 50,000 appearances; each import supports at most 100 groups, 10,000 assignments and 2 MiB. Similarity scores are not identity probabilities, and model quality on a particular footage collection requires human review.

## Local data and API

The **Footage Review Library** folder beside the built app contains clip references, scan receipts, crops, reviewed groups, API receipts and `Clustering` work. Back up that whole library, and keep source videos available for playback. Building and initializing the source checkout do not import footage or scan a library. No prepared private footage is included.

The API listens only on `127.0.0.1` when requested. Tokens remain in memory and change when the API restarts; built-in clustering connects automatically. External clients use the current endpoint and token from **Settings → Integrations**. Leave browser origin blank for the built-in native client. If another service occupies the port, choose an unused port rather than stopping that service.

See [API.md](API.md), the [API quick reference](docs/FOOTAGE_REVIEW_API_QUICK_REFERENCE.md), and the [original 1.2 API-v1 PDF](docs/Footage_Review_API_Quick_Reference.pdf) for protocol contracts, limits and idempotent import behavior. Library data, crops, embeddings, credentials, generated bundles and local backups are excluded from Git.

## Verification and versions

```bash
./script/check.sh --metadata
./script/check.sh
./script/build_and_run.sh --build-only
./script/check.sh --bundle
```

The default check runs native settings/contract tests and managed-process recovery against the prepared submodule. Recovery requires verified models. The positive model/import test additionally requires `CLUSTER_NATIVE_E2E_ASSETS` pointing to a directory with two public-sample JPEG crops (`crop-1.jpg`, `crop-2.jpg`) and a valid `source.mp4`; otherwise it is explicitly skipped. Tests use temporary libraries, not operator footage. `FOOTAGE_REVIEW_LIBRARY` can select a separate prepared library for isolated GUI checks.

`Version.env` owns the app's marketing version and build number. The build script derives the bundle metadata from it. [RELEASING.md](docs/RELEASING.md) records version ownership, verification, publication boundaries and recovery. Native build/CI checks do not establish real-footage clustering quality or human acceptance.

The [validation record](VALIDATION.md) separates tested source/build behavior from remaining GUI and operator acceptance. The [migration notes](docs/MIGRATION.md) explain source ownership and local-data recovery.

## License

Native source is licensed under [Apache License 2.0](LICENSE). Cluster Grouper is a separately pinned submodule with its own license and dependency/model notices. Downloaded models and third-party dependencies retain their respective licenses.
