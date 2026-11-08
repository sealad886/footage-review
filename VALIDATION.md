# Standalone extraction validation

Date: 8 November 2026. Source project: Footage Review 1.3.0, build 5. This record distinguishes local source/build evidence from hosted CI and operator acceptance.

- Relocation preserved the original source snapshots and every private-library file by SHA-256. The old project path redirects to the standalone checkout. Private libraries, build output and receipts are excluded from this source repository.
- Native portability changes removed automatic private seed-inventory loading. New libraries start empty; ordinary Import Clips and existing scan/archive/API behavior remain available.
- All 12 native tests passed locally: six Settings tests, three service contract tests, two actual managed-process recovery tests and one actual YuNet/SFace export/review/import round trip with two public-sample appearances. The Settings regressions cover the new submodule default, backed-up one-time migration and custom overrides.
- The pinned Cluster Grouper backend was prepared using locked Python 3.13 dependencies. Both local model files passed their pinned checksum checks. No Node.js process is required.
- The canonical build script produced an ad-hoc signed app. Plist and strict signature checks passed; built metadata matches Version.env, points at the prepared submodule and contains no SeedInventory.json.
- The new app process launched with an isolated empty library and held that fixture's lock. Computer-use window inspection returned cgWindowNotFound, so no successful GUI walkthrough of this build is claimed. The exact owned test process was then stopped; it had no clustering job.
- Actionlint, shell syntax, version/pin checks and public-source eligibility review passed. Explicit ignore exceptions preserve the native Swift Models sources despite broad global ignore rules.

Local executable SHA-256: `35166643c402b5267ddec023ad9dd10fbad0c29e717d1efae8b91cc6e3a448f7`. This identifies the tested local build; it is not a notarized or portable application artifact.

A clean recursive checkout and hosted GitHub CI are separate final checks. The public-sample round trip does not measure recognition accuracy on private footage. No real-library scan, clustering run or group import was started during extraction. The historical [1.2 record](VALIDATION_1.2.md) describes earlier bounded evidence.
