# test-certificates-tools

Helper tooling for the [test-certificate standard](https://github.com/metacraft-labs/test-certificates-spec):
the local certificate store, as a Nim library and the `test-certificates`
command.

**Documentation:** [docs/users/](./docs/users/README.md) · the standard's
[Transport §2](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Transport.md#2-the-local-certificate-store-required)
(the store) and [Tooling](https://github.com/metacraft-labs/test-certificates-spec/blob/latest/Tooling.md)
(what this tool is specified to do).

A test certificate records that a framework ran specific commands against a
specific content of a repository and that they passed. Certificates are
ephemeral: they live outside the working tree, in a per-user store that every
conforming producer writes and any tool reads, addressed by the content they
attest. Getting that store subtly wrong — a non-atomic write, a path derived
from the file instead of from the canonical payload, a lookup computed from
the wrong index — presents as "no certificates" rather than as an error. This
package is that plumbing, done once:

- **`store-root`** — where the user root and the system root are.
- **`put`** — write certificates atomically under their content-addressed
  names, with the standard's replacement rules.
- **`find`** — the candidate certificates for a commit, the index being
  committed, the working tree, or an explicit content id, from both roots,
  reporting what it searched.
- **`prune`** — bound the store without ever racing a writer.

It does **not** verify, issue or sign certificates. `find` returns candidates;
a framework's verifier judges them.

## Installation

There are no binary releases yet. Build from source with Nim 2.2 or later:

```sh
git clone https://github.com/metacraft-labs/test-certificates-tools
cd test-certificates-tools
nim c -d:release -o:test-certificates src/test_certificates_cli.nim
```

or with Nix:

```sh
nix build github:metacraft-labs/test-certificates-tools
./result/bin/test-certificates --help
```

As a Nim library, put `src/` on the module path (or `nimble install`) and
`import test_certificates`. It depends on nothing beyond the Nim standard
library.

## Quickstart

```console
$ test-certificates store-root
user: /home/alice/.local/state/test-certificates
system: /var/lib/test-certificates/1000

$ test-certificates put cert.toml
/home/alice/.local/state/test-certificates/v1/git-tree-sha1/9f8e…/de22….toml

$ some-daemon-client --issue | test-certificates put -

$ test-certificates find --staged          # in a pre-commit hook
$ test-certificates find --worktree --paths src/db
$ test-certificates find --commit HEAD
$ test-certificates find --content git-tree-sha1:9f8e7d6c5b4a3928170695e4d3c2b1a099887766

$ test-certificates prune --keep 20
```

`find` prints candidate paths on standard output and what it searched on
standard error, and exits 0 when candidates exist, 1 when none were found,
and 2 when the content id could not be computed.

From Nim:

```nim
import test_certificates

let roots = nativeRoots()
let written = putCertificate(roots.user, readFile("cert.toml"))
if not written.ok:
  echo written.problem

let report = find(roots, FindQuery(byContent: false, repository: ".",
                                   state: stagedState()))
for candidate in report.candidates:
  echo candidate.path
```

Every operation returns its errors in its result; nothing raises to the
caller, terminates the process or logs.

## More

- [User guide](./docs/users/README.md) — every command and library call.
- [Contributor guide](./docs/contributors/architecture.md) — design, the
  races it handles, and how the tests are built.
- [AGENTS.md](./AGENTS.md) — build, test and lint commands.

Licensed under the [Apache License, Version 2.0](./LICENSE).
