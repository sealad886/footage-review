# Version and release policy

Footage Review is one native application release unit. Its supported contract includes the macOS UI and controls, local library persistence, API v1, reviewed-import semantics and the managed-backend integration. Cluster Grouper is a separately versioned upstream repository pinned by the Git submodule; its version is not changed by an app release.

## Ownership

| Value | Owner | Derived output |
|---|---|---|
| Marketing version | Maintainer-reviewed `APP_VERSION` in `Version.env` | Bundle name and `CFBundleShortVersionString` |
| Build identity | Maintainer-reviewed `APP_BUILD` in `Version.env` | `CFBundleVersion` |
| Supported macOS | SwiftPM's macOS 26 target and the checked bundle metadata | `LSMinimumSystemVersion=26.0` |
| Clustering implementation | Recorded `External/cluster-grouper` Git commit | Build's absolute `ClusterGrouperRepository` source path |

The maintainer is the sole version writer. No Release Please, automatic bump writer, tagging workflow, publisher, signing identity or store upload is configured. `Version.env` is parsed as data; overrides from the shell environment do not replace it. Keep three numeric marketing components without leading zeroes and a positive build integer from 1 through 9999. Apple marketing metadata does not accept arbitrary SemVer prerelease strings.

Use Semantic Versioning for reviewed public contract changes: compatible corrections are patch, compatible features are minor, and incompatible behavior or supported-platform changes are major. Preserve the existing release number while work is pending; compute the next version from a verified immutable release baseline and the cumulative change. Build identity advances when a distinct distributable build is deliberately prepared. A repeated local development build is not publication.

The historical 1.2 validation and prior 1.3.0 development bundles describe local work, not evidence that a GitHub tag or public application release exists. Establish the first public baseline explicitly. Never retag a published version or replace its artifact bytes.

## Candidate checks

Start with a clean source checkout and the exact recorded submodule commit:

```bash
./script/setup.sh
./script/check.sh --metadata
./script/check.sh
./script/build_and_run.sh --build-only
./script/check.sh --bundle
```

`setup.sh` initializes submodules, prepares locked Python 3.13 dependencies and verifies model checksums. It refuses a pre-existing modified or differently pinned submodule, preserving work for deliberate reconciliation. `--backend-only` omits model setup for backend-only development; the full managed recovery test still needs models.

`check.sh` checks shell/version metadata and verifies native model source files are not excluded by broad user-level ignore rules. Its default test mode runs Swift tests with the prepared pinned backend. Actual-model positive testing additionally needs public-sample assets as documented in the README. `--bundle` checks the resulting marketing version, build number, deployment target, canonical clustering path, absence of the former seed inventory and strict code signature.

The build stages a fresh bundle and signs it ad-hoc only after a successful Swift build. It refuses to replace a running executable, including one launched through a filesystem redirect. Replaced app bundles are preserved under ignored `.build/previous-bundles/<UTC timestamp>/`. Existing adjacent libraries are not replaced. Keep evidence for the exact executable and bundle metadata, source commit, submodule commit, model checksums and any explicitly tested GUI flow.

CI runs these checks on the maintained `macos-26` hosted image using immutable action revisions and uv 0.13.7. Swift 6.2 or newer is required by the scripts and package. The runner label is maintained, not an immutable OS image. CI has read-only repository permission and does not upload an app, tag a version or create a release. Hosted success must be read from the actual run; configuration alone does not prove it executed.

## Publication boundaries

A candidate passes only the checks actually run. Source compilation, native tests, ad-hoc signing, GUI behavior, recognition quality, notarization and operator acceptance are separate evidence. The current bundle depends on the prepared source checkout and is not a self-contained portable distribution.

Commit, push, tag, GitHub Release creation, Developer ID signing, notarization, installer publication and installation into another environment each require applicable explicit authorization. Credentials, a successful check or this policy do not grant it. Before an authorized release, verify the exact reviewed source revision, confirm its submodule is publicly retrievable, rebuild the final artifact, inspect its metadata and signature, and record SHA-256 hashes. Publication must use that exact revision and immutable version identity.

## Recovery

For a failed build or check, keep the previous bundle and library intact, correct the failure, then rerun the narrow failed check. A failed stage does not replace the previous app. To restore a retained local bundle, quit the current copy, preserve any new bundle separately, and copy the chosen previous bundle back to `dist/`; retain the active library and source-video paths. Rebuild after moving the checkout so the clustering path is current.

Never delete or reset a library to solve a version or dependency problem. Preserve a lost-response import and retry its original saved ID and bytes. After an interrupted job, use explicit Resume. If a public release is incorrect, prepare a new corrective version rather than rewriting the published tag or artifact.

Primary tool references: [SwiftPM manifest](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html), [Apple bundle version](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion), [Git submodules](https://git-scm.com/docs/git-submodule), [uv projects](https://docs.astral.sh/uv/guides/projects/), [macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md), [checkout v7.0.0](https://github.com/actions/checkout/releases/tag/v7.0.0), and [setup-uv v10.3.3](https://github.com/astral-sh/setup-uv/releases/tag/v10.3.3).
