// Release smoke check, run by the shared release tooling against an
// unpacked archive (and, on Linux, against the installed .deb and .rpm in
// clean distribution containers): `node smoke.cjs <root> <target> [probe]`.
//
// No mocks: the shipped binary writes a certificate into a scratch store and
// finds it again. It needs no git, which the distribution containers lack.
const { execFileSync } = require("node:child_process");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const [root, target] = process.argv.slice(2);
const exe = path.join(
  root,
  "bin",
  "test-certificates" + (target.startsWith("windows") ? ".exe" : ""),
);
const store = fs.mkdtempSync(
  path.join(os.tmpdir(), "test-certificates-smoke-"),
);
const env = { ...process.env, TEST_CERTIFICATES_DIR: store };
const run = (args, input) =>
  execFileSync(exe, args, { encoding: "utf8", env, input, timeout: 30000 });

try {
  assert.match(run(["--version"]), /^test-certificates \d+\.\d+\.\d+\n$/);
  assert.match(run(["--help"]), /hook pre-push/);
  assert.match(
    run(["store-root"]),
    new RegExp("^user: " + store.replace(/[\\^$.*+?()[\]{}|]/g, "\\$&"), "m"),
  );

  const content = "git-tree-sha1:" + "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
  const certificate = [
    'schema = "test-certificate.v1"',
    "",
    "[certificate]",
    'framework = "release-smoke"',
    'project = "test-certificates"',
    'platform = "' + target + '"',
    'targets = ["smoke"]',
    'result = "passed"',
    'issued_at = "2026-10-27T00:00:00Z"',
    'issuer = "release"',
    "",
    "[certificate.vcs]",
    'repo = "test-certificates"',
    'content = "' + content + '"',
    "untracked = false",
    "",
    "[[certificate.command]]",
    'argv = ["smoke"]',
    "",
  ].join("\n");
  const written = run(["put", "-"], certificate).trim();
  assert(fs.existsSync(written), "put wrote " + written);
  assert.equal(fs.readFileSync(written, "utf8"), certificate);
  assert.equal(run(["find", "--content", content]).trim(), written);
} finally {
  fs.rmSync(store, { recursive: true, force: true });
}
