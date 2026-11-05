## The package version.
##
## ``test_certificates.nimble`` declares the version the release tooling and
## the flake read; this module carries the same value into the code, inside
## the package's own source tree, so the sources compile wherever that tree is
## shipped, vendored or installed. ``just bump-version`` writes both, and
## ``tests/t_version.nim`` refuses a mismatch between them.

const Version* = "0.1.0"
