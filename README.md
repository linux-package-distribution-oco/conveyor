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
