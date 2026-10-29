# test-certificates-tools

Helper tooling for the [test-certificate standard](https://github.com/metacraft-labs/test-certificates-spec):
the local certificate store and its git-notes carrier, as a Nim library and
the `test-certificates` command.

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
- **`notes publish` / `import` / `push` / `fetch`** — carry certificates
  with a push in a git notes ref keyed by tree, and merge concurrent pushes
  as a union so no one's certificates are lost.
- **`hook pre-push`** — a complete `pre-push` hook body: every push carries
  the certificates for the commits it introduces, and never fails because of
  them. `hook install` installs it where no hook exists yet.

It does **not** verify, issue or sign certificates. `find` returns candidates;
a framework's verifier judges them.

## Installation

With Nix:

```sh
nix run github:metacraft-labs/test-certificates-tools -- --help
nix profile install github:metacraft-labs/test-certificates-tools
```

From a [GitHub release](https://github.com/metacraft-labs/test-certificates-tools/releases),
once one is published: archives for Linux x86_64 (also `.deb` and `.rpm`),
macOS aarch64 and Windows x86_64. Or build from source with Nim 2.2 or later:

```sh
git clone https://github.com/metacraft-labs/test-certificates-tools
cd test-certificates-tools
nim c -d:release -o:test-certificates src/test_certificates_cli.nim
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

$ test-certificates notes publish origin/main..HEAD   # store -> local notes ref
$ test-certificates notes push origin                  # union-merges on a race
$ test-certificates notes fetch origin && test-certificates notes import

$ test-certificates hook install                      # every push carries them
```

`find` prints candidate paths on standard output and what it searched on
standard error. It exits 0 when candidates exist, 1 for a completed empty
search, 2 when the content id could not be computed, 3 when no candidates
were found and a root could not be read or resolved, and 64 for a usage error.
An unreadable root is reported even when a candidate in the other root
makes the command succeed.

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
- [Releasing](./docs/contributors/releasing.md) — versioning and what a
  `v<version>` tag publishes.
- [AGENTS.md](./AGENTS.md) — build, test and lint commands.

Licensed under the [Apache License, Version 2.0](./LICENSE).
