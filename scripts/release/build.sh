#!/usr/bin/env bash
# Release build for one POSIX target, run by the shared release workflow
# inside this flake's `release` shell: `bash scripts/release/build.sh
# <target>`. common.sh (from metacraft-github-actions/release-tools) sets
# the target's compiler flags and the staging directory; release_finish
# verifies the staged payload and packages it.
# Variables below are initialized by the pinned shared common.sh.
# shellcheck disable=SC2154,SC1091
set -euo pipefail
source "${RELEASE_TOOLS:?}/common.sh" "$@"
nim c "${release_nim_flags[@]}" --hints:off \
  --nimcache:"build/nimcache/release-$release_target" \
  --out:"$release_stage/bin/test-certificates" src/test_certificates_cli.nim
cp LICENSE NOTICE "$release_stage/"
release_finish
