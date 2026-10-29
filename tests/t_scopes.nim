## scopes: Tooling §3.1 — the scopes a repository declares in git
## configuration, the scoped trees of commits in them, and their travel
## through ``notes publish``, ``notes import`` and the ``pre-push`` hook.
## Real repositories, real bare remotes, real stores, the built executable.
##
## * declared_scopes_are_read_literally_and_validated — one scope per
##   section, one literal path per value; duplicates merged; every invalid
##   form reported.
## * scoped_trees_match_the_content_id_recipe — the batched tree walk
##   against Content-Id §4.1's recipe run by hand with plain git, over
##   commits with nested, overlapping, absent, file and blocked paths and a
##   gitlink.
## * scoped_trees_of_unusual_names_match_the_recipe — spaces, a newline,
##   non-ASCII, symbolic links, and two scopes whose labels print alike.
## * scoped_certificates_are_published_and_imported_on_their_scoped_trees —
##   publish, push, a fresh clone's fetch and import, then ``find --paths``.
## * an_invalid_declaration_publishes_and_imports_nothing
## * the_hook_carries_declared_scopes_only
##
## No mocks.

import std/[sequtils, tables, unittest]
import ./helpers
import test_certificates

const Ref = DefaultNotesRef

proc recipeTree(dir, tree: string, scope: openArray[string], scratch: string): string =
  ## Content-Id §4.1, "Scoped", typed out with plain git: the independent
  ## answer the tool's walk is checked against.
  let index = scratch / "recipe-index"
  removeFile(index)
  let env = @[("GIT_INDEX_FILE", index)]
  check gitWith(dir, ["read-tree", "--empty"], env).exitCode == 0
  let listing = gitWith(
    dir,
    @["--literal-pathspecs", "ls-tree", "-r", "-z", "--full-tree", tree, "--"] & @scope,
    [],
  )
  check listing.exitCode == 0
  if listing.stdout.len > 0:
    check gitWith(dir, ["update-index", "-z", "--index-info"], env, listing.stdout).exitCode ==
      0
  let written = gitWith(dir, ["write-tree"], env)
  check written.exitCode == 0
  written.stdout.strip()

proc declare(dir, name: string, paths: varargs[string]) =
  for p in paths:
    discard gitIn(dir, ["config", "--add", ScopeSection & "." & name & ".path", p])

proc write(dir, path, text: string) =
  createDir(parentDir(dir / path))
  writeFile(dir / path, text)

proc certifyTree(c: Clone, tree: string, target = "t-unit") =
  putIn(c, certificateText("git-tree-sha1:" & tree, targets = @[target]))

proc scoped(c: Clone, rev: string, scope: openArray[string]): string =
  let computed = computeContentId(c.dir, commitState(rev), scope)
  doAssert computed.outcome == coComputed, computed.problem
  computed.id["git-tree-sha1:".len ..^ 1]

suite "declared scopes":
  test "declared_scopes_are_read_literally_and_validated":
    let repo = newRepo()
    defer:
      cleanup(repo)
    var d = declaredScopes(repo)
    check d.ok
    check d.scopes.len == 0

    declare(repo, "db", "src/db", "Cargo.lock", "src/db")
    declare(repo, "Docs", "docs/a b*[x]") # Literal: spaces and glob characters.
    declare(repo, "again", "Cargo.lock", "src/db") # The same set as "db".
    d = declaredScopes(repo)
    checkpoint $d.problems
    check d.ok
    check d.scopes.len == 2
    check d.scopes[0].paths == @["Cargo.lock", "src/db"]
    check d.scopes[0].names == @["db", "again"]
    check d.scopes[1].paths == @["docs/a b*[x]"]
    check d.scopes[1].names == @["Docs"] # The section name keeps its case.

    # Each invalid form is reported, and nothing is answered.
    for (key, value) in [
      (ScopeSection & ".bad.path", "src/"),
      (ScopeSection & ".bad.path", "./src"),
      (ScopeSection & ".bad.path", "a//b"),
      (ScopeSection & ".bad.paths", "src"),
      (ScopeSection & ".path", "src"),
    ]:
      let probe = newRepo()
      discard gitIn(probe, ["config", "--add", key, value])
      let bad = declaredScopes(probe)
      checkpoint key & " = " & value
      check not bad.ok
      check bad.problems.len == 1
      check bad.scopes.len == 0
      cleanup(probe)
    # A value-less key (`path` with no `=`), written by hand.
    let bare = newRepo()
    defer:
      cleanup(bare)
    let config = bare / ".git" / "config"
    writeFile(config, readFile(config) & "[testCertificatesScope \"x\"]\n\tpath\n")
    let valueless = declaredScopes(bare)
    check not valueless.ok
    check "has no value" in valueless.problems.join("\n")

  test "scoped_trees_match_the_content_id_recipe":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let repo = scratch / "r"
    createDir(repo)
    discard gitIn(repo, ["init", "-q"])
    write(repo, "src/db/a.c", "a\n")
    write(repo, "src/db/deep/b.c", "b\n")
    write(repo, "src/dbx/c.c", "c\n")
    write(repo, "lib/db/a.c", "a\n") # The same files as src/db: distinct scope.
    write(repo, "top", "top\n")
    write(repo, "blocker", "a file where a directory would be\n")
    commitAll(repo, "one")
    let c1 = gitIn(repo, ["rev-parse", "HEAD"]).strip()
    write(repo, "src/db/a.c", "a2\n")
    setFilePermissions(repo / "top", {fpUserRead, fpUserWrite, fpUserExec})
    commitAll(repo, "two")
    let c2 = gitIn(repo, ["rev-parse", "HEAD"]).strip()
    # A gitlink, added straight to the index (`add -A` would drop it again).
    discard gitIn(
      repo, ["update-index", "--add", "--cacheinfo", "160000," & c1 & ",sub/module"]
    )
    write(repo, "lib/db/new.c", "n\n")
    discard gitIn(repo, ["add", "lib/db/new.c"])
    discard gitIn(repo, ["commit", "-q", "-m", "three"])
    let c3 = gitIn(repo, ["rev-parse", "HEAD"]).strip()

    let scopes = @[
      DeclaredScope(names: @["a"], paths: @["src/db"]),
      DeclaredScope(names: @["b"], paths: @["lib/db"]),
      DeclaredScope(names: @["c"], paths: @["src", "src/db/deep"]), # Overlapping.
      DeclaredScope(names: @["d"], paths: @["missing", "top"]),
      DeclaredScope(names: @["e"], paths: @["blocker/x", "nowhere/at/all"]),
      DeclaredScope(names: @["f"], paths: @["sub/module", "src/db/deep/b.c"]),
    ]
    var trees: seq[string]
    for c in [c1, c2, c3]:
      trees.add treeOf(repo, c)
    let computed = scopedTrees(repo / "src", 40, trees, scopes)
    checkpoint computed.problem
    check computed.ok
    for t in trees:
      check computed.trees[t].len == scopes.len
      for i, s in scopes:
        checkpoint t & " " & scopeLabel(s.paths)
        check computed.trees[t][i] == recipeTree(repo, t, s.paths, scratch)
    # The scope matching nothing is the empty tree; src/db and lib/db differ
    # although they hold the same files in the first commit.
    check computed.trees[trees[0]][4] == EmptyTreeSha1
    check computed.trees[trees[0]][0] != computed.trees[trees[0]][1]
    # No scopes, or no trees: nothing to do, and no failure.
    check scopedTrees(repo, 40, trees, []).ok
    check scopedTrees(repo, 40, [], scopes).ok

  test "scoped_trees_of_unusual_names_match_the_recipe":
    # Names with spaces, a newline, non-ASCII bytes and the `", "` a scope
    # label prints between paths; a symbolic link; a symbolic link standing
    # where a directory would be. The last two scopes print alike as labels
    # and find identical entries (mode and object) at their paths: only the
    # paths tell their scoped trees apart.
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let repo = scratch / "r"
    createDir(repo)
    discard gitIn(repo, ["init", "-q"])
    write(repo, "a b/c d", "spaces\n")
    write(repo, "new\nline", "newline\n")
    write(repo, "ünï/cödé", "unicode\n")
    write(repo, "a\", \"b", "X\n")
    write(repo, "c", "Y\n")
    write(repo, "a", "X\n")
    write(repo, "b\", \"c", "Y\n")
    createSymlink("a b", repo / "link")
    commitAll(repo, "one")
    let tree = treeOf(repo, "HEAD")
    let scopes = @[
      DeclaredScope(names: @["s"], paths: @["a b"]),
      DeclaredScope(names: @["n"], paths: @["new\nline"]),
      DeclaredScope(names: @["u"], paths: @["ünï"]),
      DeclaredScope(names: @["l"], paths: @["link"]),
      DeclaredScope(names: @["through"], paths: @["link/c d"]),
      DeclaredScope(names: @["x"], paths: @["a\", \"b", "c"]),
      DeclaredScope(names: @["y"], paths: @["a", "b\", \"c"]),
    ]
    check scopeLabel(scopes[5].paths) == scopeLabel(scopes[6].paths)
    let computed = scopedTrees(repo, 40, [tree], scopes)
    checkpoint computed.problem
    require computed.ok
    for i, s in scopes:
      checkpoint scopeLabel(s.paths)
      check computed.trees[tree][i] == recipeTree(repo, tree, s.paths, scratch)
    check computed.trees[tree][4] == EmptyTreeSha1 # Not followed.
    check computed.trees[tree][5] != computed.trees[tree][6]

suite "scoped notes":
  test "scoped_certificates_are_published_and_imported_on_their_scoped_trees":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    write(a.dir, "src/x", "x\n")
    write(a.dir, "lib/y", "y\n")
    write(a.dir, "other", "o\n")
    commitAll(a.dir)
    discard gitIn(a.dir, ["push", "-q", "origin", "HEAD:refs/heads/main"])
    declare(a.dir, "both", "src", "lib")
    declare(a.dir, "src-only", "src")
    let both = scoped(a, "HEAD", ["lib", "src"])
    let srcOnly = scoped(a, "HEAD", ["src"])
    let libOnly = scoped(a, "HEAD", ["lib"])
    let own = treeOf(a.dir, "HEAD")
    check toHashSet([both, srcOnly, libOnly, own]).len == 4
    for t in [both, srcOnly, libOnly]:
      certifyTree(a, t)
    let published = tc(a, ["notes", "publish", "HEAD"])
    checkpoint published.errors
    check published.exitCode == 0
    check "in scope [\"lib\", \"src\"]" in published.errors
    check "in scope [\"src\"]" in published.errors
    # `lib` alone is declared by no section: its certificate stays local.
    check noteKeys(a.dir) == toHashSet([both, srcOnly])
    # Publishing twice adds nothing.
    let again = tc(a, ["notes", "publish", "HEAD"])
    check again.exitCode == 0
    check (Ref & " unchanged") in again.errors
    check tc(a, ["notes", "push", "origin"]).exitCode == 0

    # A fresh clone with the same declaration imports both scoped records
    # under their scoped content ids, and finds them by scope.
    let b = newClone(scratch, remote, "b")
    declare(b.dir, "x", "src", "lib")
    declare(b.dir, "y", "src")
    check tc(b, ["notes", "fetch", "origin"]).exitCode == 0
    let imported = tc(b, ["notes", "import"])
    checkpoint imported.errors
    check imported.exitCode == 0
    check imported.output.splitLines().filterIt(it.len > 0).len == 2
    for t in [both, srcOnly]:
      let path = b.store / toNative(relativeOf(certificateText("git-tree-sha1:" & t)))
      check fileExists(path)
    check tc(b, ["find", "--commit", "HEAD", "--paths", "src", "lib"]).exitCode == 0
    check tc(b, ["find", "--commit", "HEAD", "--paths", "src"]).exitCode == 0
    check tc(b, ["find", "--commit", "HEAD", "--paths", "lib"]).exitCode == 1
    check tc(b, ["find", "--commit", "HEAD"]).exitCode == 1

    # Without the declaration, a consumer looks only at the unscoped tree.
    let c = newClone(scratch, remote, "c")
    check tc(c, ["notes", "fetch", "origin"]).exitCode == 0
    let plain = tc(c, ["notes", "import"])
    check plain.exitCode == 0
    check plain.output == ""
    check "no note" in plain.errors

  test "an_invalid_declaration_publishes_and_imports_nothing":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    write(a.dir, "src/x", "x\n")
    write(a.dir, "other", "o\n") # So the scoped tree is not the whole tree.
    commitAll(a.dir)
    certifyTree(a, treeOf(a.dir, "HEAD"))
    certifyTree(a, scoped(a, "HEAD", ["src"]))
    declare(a.dir, "good", "src")
    declare(a.dir, "bad", "src/")
    let published = tc(a, ["notes", "publish", "HEAD"])
    checkpoint published.errors
    check published.exitCode == 1
    check "invalid scope declaration" in published.errors
    check git(a.dir, ["rev-parse", "--verify", "--quiet", Ref]).ok == false

    # Publish with a valid declaration, then break it before importing.
    discard gitIn(a.dir, ["config", "--unset", ScopeSection & ".bad.path"])
    check tc(a, ["notes", "publish", "HEAD"]).exitCode == 0
    check noteKeys(a.dir).len == 2
    discard gitIn(a.dir, ["config", ScopeSection & ".good.pathz", "src"])
    let fresh = Clone(
      dir: a.dir,
      store: scratch / "fresh-store",
      env: isolatedEnv(scratch, scratch / "fresh-store"),
    )
    let imported = tc(fresh, ["notes", "import"])
    checkpoint imported.errors
    check imported.exitCode == 1
    check "invalid scope declaration" in imported.errors
    check imported.output == ""
    check not dirExists(fresh.store)

  test "the_hook_carries_declared_scopes_only":
    let scratch = scratchDir()
    defer:
      cleanup(scratch)
    let remote = newBareRemote(scratch)
    let a = newClone(scratch, remote, "a")
    let hook = a.dir / ".git" / "hooks" / "pre-push"
    writeFile(hook, "#!/bin/sh\nexec '" & cliBinary() & "' hook pre-push \"$@\"\n")
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec})
    declare(a.dir, "src", "src")
    write(a.dir, "src/x", "x\n")
    write(a.dir, "lib/y", "y\n")
    commitAll(a.dir)
    let srcTree = scoped(a, "HEAD", ["src"])
    let libTree = scoped(a, "HEAD", ["lib"])
    certifyTree(a, srcTree)
    certifyTree(a, libTree) # Not declared: never published.
    let pushed = gitWith(a.dir, ["push", "origin", "HEAD:refs/heads/main"], a.env)
    checkpoint pushed.stderr
    check pushed.exitCode == 0
    check "1 certified tree(s) among 1 pushed commit(s)" in pushed.stderr
    check noteKeys(remote) == toHashSet([srcTree])
    check noteKeys(a.dir) == toHashSet([srcTree])

    # A commit that changes only what is out of scope shares the scoped
    # tree: its push publishes nothing new.
    write(a.dir, "lib/y", "y2\n")
    commitAll(a.dir)
    let tip = gitIn(remote, ["rev-parse", Ref]).strip()
    let unchanged = gitWith(a.dir, ["push", "origin", "HEAD:refs/heads/main"], a.env)
    checkpoint unchanged.stderr
    check unchanged.exitCode == 0
    check gitIn(remote, ["rev-parse", Ref]).strip() == tip

    # An invalid declaration: reported, nothing published or pushed, and
    # the branch still lands.
    write(a.dir, "src/x", "x3\n")
    commitAll(a.dir)
    certifyTree(a, scoped(a, "HEAD", ["src"]))
    certifyTree(a, treeOf(a.dir, "HEAD"))
    discard gitIn(a.dir, ["config", ScopeSection & ".src.pth", "src"])
    let localTip = gitIn(a.dir, ["rev-parse", Ref]).strip()
    let invalid = gitWith(a.dir, ["push", "origin", "HEAD:refs/heads/main"], a.env)
    checkpoint invalid.stderr
    check invalid.exitCode == 0
    check "invalid scope declaration" in invalid.stderr
    check "certificates were NOT fully propagated" in invalid.stderr
    check gitIn(remote, ["rev-parse", Ref]).strip() == tip
    check gitIn(a.dir, ["rev-parse", Ref]).strip() == localTip
    check gitIn(remote, ["rev-parse", "refs/heads/main"]) ==
      gitIn(a.dir, ["rev-parse", "HEAD"])
