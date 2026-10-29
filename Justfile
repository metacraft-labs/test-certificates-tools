# test-certificates-tools — run `just` for the recipe list.
#
# Every recipe runs inside the dev shell (`nix develop`, or direnv with the
# committed `.envrc`), which provides nim, nph, nixfmt and git.

set shell := ["bash", "-euo", "pipefail", "-c"]

bin := "build/bin/test-certificates"

default:
    @just --list

# Build the `test-certificates` executable into build/bin/.
build:
    nim c -d:release --hints:off -o:{{ bin }} src/test_certificates_cli.nim

# Run the full test suite. The tests drive the BUILT executable (concurrent
# publishers are separate processes), so this builds it first; they never
# build it themselves. The conformance test reads the specification's vectors
# from a sibling `../test-certificates-spec` checkout (or
# $TEST_CERTIFICATES_SPEC_DIR) at the commit `tests/spec-vectors.pin` names.
test: build
    #!/usr/bin/env bash
    set -euo pipefail
    export TEST_CERTIFICATES_BIN="$PWD/{{ bin }}"
    mkdir -p build/tests
    failed=()
    for t in tests/t_*.nim; do
      name="$(basename "$t" .nim)"
      echo "=== $name"
      if ! nim c --hints:off -o:"build/tests/$name" "$t" || ! "build/tests/$name"; then
        failed+=("$name")
      fi
    done
    if [ "${#failed[@]}" -gt 0 ]; then
      echo "FAILED: ${failed[*]}" >&2
      exit 1
    fi
    echo "all test files passed"

# Run one test file: `just test-one t_put`.
test-one name: build
    TEST_CERTIFICATES_BIN="$PWD/{{ bin }}" nim c -r --hints:off -o:build/tests/{{ name }} tests/{{ name }}.nim

# All linters and checks.
lint: lint-nim lint-nix

# Formatting is nph's, and every module type-checks with no warnings. The
# Windows and macOS code paths, the tests included, are type-checked by cross
# `nim check`s (on macOS `std/posix` differs: signal numbers are variables).
lint-nim:
    nph --check src tests
    for f in src/test_certificates.nim src/test_certificates_cli.nim tests/t_*.nim tests/process_helper.nim; do \
      nim check --hints:off --warningAsError:UnusedImport:on "$f"; \
    done
    for f in src/test_certificates.nim src/test_certificates_cli.nim tests/t_*.nim tests/process_helper.nim; do \
      nim check --hints:off --os:windows "$f"; \
    done
    for f in src/test_certificates.nim src/test_certificates_cli.nim tests/t_*.nim tests/process_helper.nim; do \
      nim check --hints:off --os:macosx --cpu:arm64 "$f"; \
    done

lint-nix:
    nixfmt --check flake.nix

# Auto-format all source files.
format: format-nim format-nix

format-nim:
    nph src tests

format-nix:
    nixfmt flake.nix

# Remove build outputs and the per-checkout nimcache.
clean:
    rm -rf build .nimcache

alias t := test
alias fmt := format

# Set the package version (the nimble file is the single source of truth;
# the flake and `test-certificates --version` read it): `just bump-version 0.2.0`.
bump-version new:
    sed -i.bak -E 's/^version = "[^"]*"/version = "{{ new }}"/' test_certificates.nimble && rm test_certificates.nimble.bak
    grep -n '^version' test_certificates.nimble
