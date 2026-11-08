# Standalone project extraction

Footage Review is maintained in its own repository at https://github.com/sealad886/footage-review. A conventional local checkout is `~/zzApps/footage-review`. Video recovery and folder comparison remain in VideoRebuild.

The project was extracted from VideoRebuild's ignored review-app output directory. The original local path redirects to this canonical project so existing local links and development references continue to resolve. New clones need only this repository and its recorded submodule; the redirect is not part of the public source.

The migration moved the existing adjacent review library with the project and verified every library file against its original SHA-256. It did not scan footage, cluster the operator's library, or import reviewed groups. Libraries, crops, scan receipts, model files, virtual environments, build output and migration backups remain local and ignored. Historical validation receipts refer to local build evidence rather than downloadable source artifacts.

Cluster Grouper is pinned at `External/cluster-grouper`. Run `./script/setup.sh` once to prepare the recorded dependency, then `./script/build_and_run.sh`. The native application records this prepared checkout in its generated plist. Settings migrate only the former default repository path, back up that value, and preserve custom overrides. No private seed inventory is bundled or automatically imported; new libraries start empty and use Import Clips.

Original source snapshots and the private migration/hash receipt are under `.migration-backups/extraction-20261108/`. Before any rollback, quit the app and preserve subsequent edits and review work. Inspect the original source hashes and copy only the intended files from `source/`; do not overwrite the library with a source rollback. Moving a working checkout back also requires updating local references and preserving its Git metadata, submodule and current history. Public commit history and release tags are not rewritten by a local path rollback.
