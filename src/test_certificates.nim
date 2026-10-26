## The test-certificates store operations, as a library.
##
## Every command of the ``test-certificates`` tool is a thin wrapper over a
## call exported here, with the same name and semantics:
##
## ============================  ==============================================
## Command                       Library call
## ============================  ==============================================
## ``store-root``                ``nativeRoots`` / ``resolveRoots``
## ``put <file>…``               ``putFile`` / ``putCertificate``
## ``find <state>``              ``find`` / ``findById``
## ``prune``                     ``pruneRoot``
## ============================  ==============================================
##
## Errors are returned in the result objects, never raised to the caller and
## never fatal, and nothing here logs: reporting is the caller's.
##
## The library implements the local certificate store of the test-certificate
## standard (Transport §2) and the content-id computations a ``find`` needs
## (Content-Id §4, §5). It does not verify, issue or sign certificates.

import
  test_certificates/[
    sha256, toml, content_id, certificate, content_state, roots, put, find, prune,
    layout,
  ]

export
  sha256, toml, content_id, certificate, content_state, roots, put, find, prune, layout
