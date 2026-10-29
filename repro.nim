## Reprobuild project file for test-certificates-tools.
##
## Declares the development environment (this repository's flake dev shell)
## and the importable library, so that a producer or a framework built with
## reprobuild can depend on the ``test_certificates`` package by name
## (``uses: "test_certificates"``). The library depends on nothing beyond
## the Nim standard library, so there is no sibling edge here; the ``uses:``
## block is only the toolchain floor matching ``test_certificates.nimble``.
##
## The test suite is run by ``just test``. Its tests drive the BUILT
## ``test-certificates`` executable (concurrent publishers are separate
## processes) and read the specification's conformance vectors from a sibling
## checkout at a pinned commit; modelling those as build edges is left for
## when the tool is packaged, rather than approximated with a script edge.

import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package test_certificates:
  devEnv:
    when not defined(windows):
      useFlakeDevShell()

  defaultToolProvisioning "path"

  uses:
    "nim >=2.2 <3.0"
    when defined(macosx):
      "clang >=14"
    else:
      "gcc >=12"

  # The umbrella module is ``src/test_certificates.nim``; consumers
  # ``import test_certificates``.
  library test_certificates
