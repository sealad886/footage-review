# Footage Review 1.2 validation

Historical record from before repository extraction. The `.build/qa` receipts mentioned below remain local build evidence and are not included in this public source repository. See the current README for the maintained build and setup workflow.

The staged app is `dist/Footage Review 1.2.app`, version 1.2, build 3. Native release compilation and ad-hoc code-signature verification passed. The build command was `./script/build_and_run.sh --build-only`. Exact binary and source SHA-256 values are recorded in `.build/qa/footage-review-1.2-build.json`.

## Native HTTP and persistence

The local final end-to-end receipt (`.build/qa/rest-api-smoke-E3482CC5-42FF-4FF5-9C4B-4504F7158529/QA.md`) covers actual application sources, a synthetic media library, URLSession requests over the IPv4 loopback listener, and a separate relaunch process.

Passed: authentication; exact CORS origin and preflight; routing and method errors; page limits; exact JPEG bytes after base64 decoding; stable IDs; fixed snapshot pagination while provider contents grow; atomic invalid-ID rejection; preservation of existing manual groups; revision/library/import-ID conflicts; durable replay without another write after relaunch; and a byte-preserving legacy metadata backup.

Regression checks passed for shared UI/API group-name equivalence, stale local drafts after an API import, and one-revision atomic name/note edits. The independent source review's two findings were fixed and re-reviewed. Focused transport tests also rejected duplicate Content-Length, Transfer-Encoding and oversized bodies; lsof showed the synthetic listener bound only to IPv4 loopback.

## Native view rendering

A separate synthetic fixture rendered the real SwiftUI views through AppKit NSHostingView. The running panel masked the token. An HTTP-reviewed group appeared in the sidebar with its member count. Stop closed the listener, and restarting changed the token. The local native state receipt (`.build/qa/api-panel-render/run-1/render-results.json`) records these results.

These were programmatic state changes and native renders, without mouse automation. Offscreen bitmap capture has transparency/vibrancy artifacts, so this is bounded rendering evidence rather than acceptance of every interactive control. Private footage and the live review library were not used or modified for API tests. A full video rescan and Python CLI suite were not run for this isolated native API change.

## Handoff

Pause scans and quit older copies before opening 1.2 against the same adjacent library. The API is stopped by default. Starting it creates a fresh token and saves API identity/import receipts in Library.json; the first migration preserves Library.before-API.json. Use 1.2 thereafter to retain its API metadata. Source and app changes remain local in this existing ignored review-app directory; no commit, push or publication was made.
