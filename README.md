# Package conveyor

**One packaging conveyor every project calls, not copies.** A project keeps one short declaration and
calls the conveyor at a pinned version; the conveyor builds, verifies, signs and publishes - Arch
(pacman) and Alpine (apk, for postmarketOS) repositories first.

Status: **in use** - lab-agent delivers through it (v0.1.47 was its first delivery). Next: snapall, then Alpine packages for postmarketOS. Its idea, decisions
(with what was rejected) and path are in [`data/`](data), shown in the
[Open Commons Observatory](https://open-commons-observatory.github.io/).

## Use

A project keeps one declaration, `packaging/conveyor.toml`, and calls the conveyor at a pinned version:

```yaml
  deliver:            # after the project cut a release tag
    uses: linux-package-distribution-oco/conveyor/.github/workflows/binaries.yml@v1
    with: { tag: ${{ needs.release.outputs.tag }} }
    permissions: { contents: write, id-token: write, attestations: write }
  publish:            # a signed pacman repository on the project's pages
    uses: linux-package-distribution-oco/conveyor/.github/workflows/publish.yml@v1
    with: { tag: ${{ needs.tag.outputs.tag }} }
    secrets: { REPO_SIGNING_KEY: ${{ secrets.REPO_SIGNING_KEY }} }
    permissions: { contents: read, pages: write, id-token: write }
```

The project keeps its build scripts, its PKGBUILD, its public key and its install test; the conveyor
does everything around them. `v1` moves with compatible improvements; `v1.x.y` never moves.

A release is said once it can be taken. The project's releaser makes it a draft, with its tag
(release-please: `"draft": true` and `"force-tag-creation": true`; release-plz: `git_release_draft = true`);
the conveyor attaches every file and then says the release. Whoever takes the newest release never
finds one with nothing to take, and needs to know nothing of how it was made.

### Alpine, for postmarketOS phones

```yaml
  alpine:             # a signed apk repository on the project's pages
    uses: linux-package-distribution-oco/conveyor/.github/workflows/alpine.yml@v1
    with: { tag: ${{ needs.tag.outputs.tag }} }
    secrets: { APK_SIGNING_KEY: ${{ secrets.APK_SIGNING_KEY }} }
    permissions: { contents: read, pages: write, id-token: write }
```

```toml
[alpine]
apkbuild = "packaging/alpine/APKBUILD"       # pkgver and the checksums are filled in for the tag
key = "packaging/alpine/NAME-DATE.rsa.pub"   # the public half; the private half is APK_SIGNING_KEY
release = "3.24"                             # the Alpine the phones run (postmarketOS v26.06: 3.24)
archs = ["aarch64"]
```

The APKBUILD is built from the tag in an Alpine container that never sees the key; packaging and the
index are signed in a fresh container, the only one given the key. Nothing is deployed unless every
package and index verifies against the committed key; after the deploy, the page's own lines are run
in a clean Alpine container and the package must install at the tagged version.

#### One repository, several packages

A project may keep more than one package in the same pages: one declaration for each (`declaration:`
names it), one call for each, in a row. The APKBUILD's whole folder is copied, so the files beside it
(`source=`, `install=`) are found by abuild; the repository's signed index covers every package - the
ones kept from the live pages and the one just built - and the front page offers each of them. A run
replaces only the packages of its own APKBUILD (its subpackages too: they share its origin), never
another's.

```yaml
  alpine-health:
    uses: linux-package-distribution-oco/conveyor/.github/workflows/alpine.yml@v1
    with: { tag: ${{ needs.tag.outputs.health }} }
    secrets: { APK_SIGNING_KEY: ${{ secrets.APK_SIGNING_KEY }} }
    permissions: { contents: read, pages: write, id-token: write }
  alpine-shell:
    needs: alpine-health          # one after the other: both write the same pages
    if: ${{ !cancelled() && needs.alpine-health.result != 'failure' && needs.tag.outputs.shell != '' }}
    uses: linux-package-distribution-oco/conveyor/.github/workflows/alpine.yml@v1
    with: { tag: ${{ needs.tag.outputs.shell }}, declaration: packaging/shell/conveyor.toml }
    secrets: { APK_SIGNING_KEY: ${{ secrets.APK_SIGNING_KEY }} }
    permissions: { contents: read, pages: write, id-token: write }
```

Both declarations name the same `repo`, `release`, `archs` and `key` (and the same `[site] title`: the
front page is rewritten by each run). A run keeps the packages the live index lists, and its
declared `name` must be its APKBUILD's `pkgname`. A run stops before the deploy if a package is live
that its site does not hold at that version, or an architecture is live that its site has no index
for (two runs overlapped, or the archs differ). `tests/alpine/run.sh` proves all of it on two fixture
packages, with a local pages server.
