# Releasing

A release is a `v<version>` tag on a commit of `stable`. Pushing the tag runs
[`.github/workflows/release.yml`](../../.github/workflows/release.yml), which
builds, verifies and publishes the GitHub release. Nothing else publishes:
promotion to `dev` or `stable` builds and tests (the CI workflow) but
releases nothing.

## The version

`test_certificates.nimble` holds the one version. The flake's package and
`test-certificates --version` read it at build time, and the release tooling
reads it from there too (`versionFile` in
[`.github/release.json`](../../.github/release.json)). Change it with
`just bump-version <x.y.z>`. The release refuses a tag that differs from
`v<version>` and a version that is not three numbers.

## What the release workflow does

It calls the shared release workflow of `metacraft-labs/metacraft-github-actions`
(`release-tools.yml`, pinned by commit), which reads `.github/release.json`:

1. **Plan.** The version, the target matrix and the exact asset names.
2. **Build, per target**, on the self-hosted runner named in
   `release.json`:
   - Linux x86_64 and macOS aarch64: `nix develop .#release --command bash
scripts/release/build.sh <target>`. The `release` dev shell carries Nim,
     Node, and on Linux zig (which links against a glibc 2.28 sysroot, so the
     binary runs on older distributions than the build host) with the ELF,
     `.deb` and `.rpm` packagers.
   - Windows x86_64: `scripts/release/build.ps1` with the shared tooling's
     pinned compiler.
   - Each build compiles `src/test_certificates_cli.nim` into a staging tree
     (`bin/`, `LICENSE`, `NOTICE`), and the shared tooling verifies the
     binary's architecture and dependencies and packs the archive (and on
     Linux the `.deb` and `.rpm`).
3. **Smoke.** [`scripts/release/smoke.cjs`](../../scripts/release/smoke.cjs)
   runs the shipped binary: `--version`, `--help`, `store-root`, and a real
   `put -` / `find --content` round trip in a scratch store. On Linux it runs
   against the archive and the installed `.deb` and `.rpm` in clean Debian
   11, Ubuntu 24.04 and AlmaLinux 9 containers.
4. **Assemble and sign** the checksum manifest (cosign, keyless).
5. **Publish** — on a tag push only — a draft release, re-verified, then made
   public.

`workflow_dispatch` runs steps 1–4 on any branch: a rehearsal before
tagging.

## Cutting one

1. On `dev`, `just bump-version <x.y.z>`; land it like any change.
2. Promote `dev` to `stable` (the branching policy's promotion pull request).
3. Tag the promoted commit on `stable` and push the tag:
   `git tag -s v<x.y.z> <commit> && git push origin v<x.y.z>`.
4. Watch the Release workflow; check the published assets and checksum
   manifest.

## Rehearsing locally (Linux)

The Linux leg can be run without CI, from a checkout of
`metacraft-labs/metacraft-github-actions` at the commit the workflow pins:

```sh
export RELEASE_TOOLS=<that checkout>/release-tools
nix develop .#release --command bash -c '
  export RELEASE_NODE=$(command -v node) RELEASE_TARGET=linux-x86_64 \
         RELEASE_VERSION=$(sed -n "s/^version = \"\(.*\)\"/\1/p" test_certificates.nimble)
  bash scripts/release/build.sh linux-x86_64 &&
  bash "$RELEASE_TOOLS/verify-linux.sh"'   # needs docker
```

It writes `dist/`, `test-logs/` and `build/release/`; delete them after.
