#!/usr/bin/env node
// Runs on Linux; only macOS Node signing/packaging is replaced with a stub.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtemp, mkdir, readFile, writeFile, copyFile, readdir, lstat, realpath, rm, symlink, access } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = fileURLToPath(new URL("../../", import.meta.url));

async function run(command, args, env) {
  const child = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", chunk => { stdout += chunk; });
  child.stderr.on("data", chunk => { stderr += chunk; });
  const [code] = await once(child, "exit");
  return { code, stdout, stderr };
}

async function inspectBundle(directory, bundleRoot = directory) {
  for (const name of await readdir(directory)) {
    const entry = path.join(directory, name);
    const stat = await lstat(entry);
    // npm 10 leaves this scope directory behind when omitting optional packages.
    // Only an empty real directory is harmless; packages, files, and links fail.
    if (name === "@msgpackr-extract" && stat.isDirectory() && (await readdir(entry)).length === 0) continue;
    assert.ok(!name.endsWith(".node"), `native binary bundled: ${entry}`);
    assert.ok(!["next", "@nestjs", "msgpackr-extract", "@msgpackr-extract"].includes(name), `unexpected dependency: ${entry}`);
    if (stat.isSymbolicLink()) {
      const target = await realpath(entry);
      assert.ok(target.startsWith(`${bundleRoot}${path.sep}`), `symlink leaves bundle: ${entry} -> ${target}`);
    } else if (stat.isDirectory()) {
      await inspectBundle(entry, bundleRoot);
    }
  }
}

test("npm discovery preserves PATH priority and supports Xcode fallbacks", async t => {
  const work = await mkdtemp(path.join(os.tmpdir(), "queuescope-npm-discovery-"));
  t.after(() => rm(work, { recursive: true, force: true }));
  const script = await readFile(path.join(root, "scripts/package-bridge.sh"), "utf8");
  const discoveryEnd = script.indexOf("\nSOURCE_BRIDGE_DIR=");
  assert.ok(discoveryEnd > 0, "packaging script must discover npm before preparing the bridge");

  const scenarios = [
    { name: "existing PATH wins over both fallbacks", available: ["preferred", "homebrew", "local"], expected: "preferred" },
    { name: "minimal PATH falls back to Homebrew", available: ["homebrew", "local"], expected: "homebrew" },
    { name: "minimal PATH falls back to usr/local", available: ["local"], expected: "local" },
  ];
  for (const { name, available, expected } of scenarios) {
    await t.test(name, async () => {
      const fixture = path.join(work, expected);
      const bins = {};
      for (const location of ["preferred", "homebrew", "local"]) {
        bins[location] = path.join(fixture, location);
        await mkdir(bins[location], { recursive: true });
        if (available.includes(location)) {
          await writeFile(path.join(bins[location], "npm"), `#!/bin/sh\nprintf '%s\\n' '${location}'\n`, { mode: 0o755 });
        }
      }
      // Exercise the production lookup unchanged except for relocating its two
      // system fallback directories into the fixture; never modify system bins.
      const discovery = script.slice(0, discoveryEnd)
        .replaceAll("/opt/homebrew/bin", bins.homebrew)
        .replaceAll("/usr/local/bin", bins.local);
      const result = await run("/bin/bash", ["-c", `${discovery}\nnpm\n`], {
        ...process.env, PATH: bins.preferred, HOME: fixture,
      });
      assert.equal(result.code, 0, result.stderr);
      assert.equal(result.stdout.trim(), expected);
    });
  }
});

test("bundle inspection allows only an empty optional scope", async t => {
  const work = await mkdtemp(path.join(os.tmpdir(), "queuescope-bundle-inspection-"));
  t.after(() => rm(work, { recursive: true, force: true }));
  const emptyBundle = path.join(work, "empty-scope");
  await mkdir(path.join(emptyBundle, "node_modules/@msgpackr-extract"), { recursive: true });
  await inspectBundle(emptyBundle);

  const rejected = [
    ["populated optional scope", "node_modules/@msgpackr-extract/msgpackr-extract-linux-x64/package.json", /unexpected dependency/],
    ["unexpected scope contents", "node_modules/@msgpackr-extract/leftover", /unexpected dependency/],
    ["unscoped optional package", "node_modules/msgpackr-extract/package.json", /unexpected dependency/],
    ["native addon", "node_modules/example/addon.node", /native binary bundled/],
    ["Next package", "node_modules/next/package.json", /unexpected dependency/],
    ["Nest package", "node_modules/@nestjs/core/package.json", /unexpected dependency/],
  ];
  for (const [name, relativePath, error] of rejected) {
    await t.test(`rejects ${name}`, async () => {
      const bundle = path.join(work, name);
      const entry = path.join(bundle, relativePath);
      await mkdir(path.dirname(entry), { recursive: true });
      await writeFile(entry, "{}");
      await assert.rejects(inspectBundle(bundle), error);
    });
  }
  await t.test("rejects an optional scope symlink even when its target is empty", async () => {
    const bundle = path.join(work, "scope-symlink");
    await mkdir(path.join(bundle, "node_modules"), { recursive: true });
    await mkdir(path.join(bundle, "empty"));
    await symlink("../empty", path.join(bundle, "node_modules/@msgpackr-extract"));
    await assert.rejects(inspectBundle(bundle), /unexpected dependency/);
  });
  await t.test("rejects a workspace symlink leaving the bundle", async () => {
    const bundle = path.join(work, "workspace-symlink");
    await mkdir(path.join(bundle, "node_modules"), { recursive: true });
    await symlink(emptyBundle, path.join(bundle, "node_modules/workspace-package"));
    await assert.rejects(inspectBundle(bundle), /symlink leaves bundle/);
  });
});

test("app bridge packaging uses its own lock outside the workspace", { timeout: 120000 }, async t => {
  const work = await mkdtemp(path.join(os.tmpdir(), "queuescope-bridge-test-"));
  t.after(() => rm(work, { recursive: true, force: true }));
  const fixture = path.join(work, "workspace with spaces");
  const source = path.join(fixture, "packages/action-bridge");
  const scripts = path.join(fixture, "scripts");
  const bin = path.join(work, "bin");
  await mkdir(source, { recursive: true });
  await mkdir(scripts);
  await mkdir(bin);
  for (const name of ["bridge.mjs", "package.json", "package-lock.json"]) {
    await copyFile(path.join(root, "packages/action-bridge", name), path.join(source, name));
  }
  for (const name of ["package-bridge.sh", "prepare-bridge.sh"]) {
    await copyFile(path.join(root, "scripts", name), path.join(scripts, name));
  }
  // A deliberately incompatible workspace and polluted hoisted dependencies.
  const workspaceManifest = JSON.stringify({ private: true, workspaces: ["packages/*"], dependencies: { next: "0.0.0", "@nestjs/core": "0.0.0" } });
  const workspaceLock = JSON.stringify({ name: "wrong-lock", lockfileVersion: 3, packages: {} });
  await writeFile(path.join(fixture, "package.json"), workspaceManifest);
  await writeFile(path.join(fixture, "package-lock.json"), workspaceLock);
  await writeFile(path.join(fixture, ".npmrc"), "workspaces=true\nignore-scripts=false\n");
  await mkdir(path.join(fixture, "node_modules/next"), { recursive: true });
  await mkdir(path.join(fixture, "node_modules/@nestjs/core"), { recursive: true });
  await symlink(source, path.join(fixture, "node_modules/bullmq-action-bridge"));
  await writeFile(path.join(scripts, "package-node.sh"), 'set -eu\nmkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"\nprintf "node-packaging-stub" > "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/node"\n');

  // Record the real install location and flags while still running actual npm ci.
  const npmLookup = await run("/bin/sh", ["-c", "command -v npm"], process.env);
  assert.equal(npmLookup.code, 0, npmLookup.stderr);
  await writeFile(path.join(bin, "npm"), '#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" > "$NPM_CALL_LOG"\nexec "$REAL_NPM" "$@"\n', { mode: 0o755 });
  const env = {
    ...process.env,
    PATH: `${bin}${path.delimiter}${process.env.PATH}`,
    REAL_NPM: npmLookup.stdout.trim(),
    NPM_CALL_LOG: path.join(work, "npm-call"),
    SRCROOT: fixture,
    DERIVED_FILE_DIR: path.join(fixture, "build/derived"),
    TARGET_BUILD_DIR: path.join(work, "products"),
    UNLOCALIZED_RESOURCES_FOLDER_PATH: "QueueScope.app/Contents/Resources",
    CONTENTS_FOLDER_PATH: "QueueScope.app/Contents",
    TMPDIR: path.join(fixture, "tmp"),
  };
  await mkdir(env.TMPDIR);
  const result = await run("/bin/bash", [path.join(scripts, "package-bridge.sh")], env);
  assert.equal(result.code, 0, `${result.stdout}\n${result.stderr}`);

  const bundle = path.join(env.TARGET_BUILD_DIR, env.UNLOCALIZED_RESOURCES_FOLDER_PATH, "BullMQActionBridge");
  const sourceLock = await readFile(path.join(source, "package-lock.json"), "utf8");
  assert.equal(await readFile(path.join(bundle, "package-lock.json"), "utf8"), sourceLock);
  assert.equal(await readFile(path.join(bundle, "bridge.mjs"), "utf8"), await readFile(path.join(source, "bridge.mjs"), "utf8"));
  const manifest = JSON.parse(await readFile(path.join(bundle, "package.json"), "utf8"));
  assert.equal(manifest.private, true);
  assert.deepEqual(manifest.dependencies, { bullmq: "5.77.0", "cron-parser": "4.9.0" });
  const installedCronParser = JSON.parse(await readFile(path.join(bundle, "node_modules/cron-parser/package.json"), "utf8"));
  assert.equal(installedCronParser.version, "4.9.0");
  const installedBullMQ = JSON.parse(await readFile(path.join(bundle, "node_modules/bullmq/package.json"), "utf8"));
  assert.equal(installedBullMQ.version, "5.77.0");

  const lockedPackages = JSON.parse(sourceLock).packages;
  const installedPackages = JSON.parse(await readFile(path.join(bundle, "node_modules/.package-lock.json"), "utf8")).packages;
  assert.ok(Object.keys(installedPackages).length > 1);
  for (const [name, installed] of Object.entries(installedPackages)) {
    assert.ok(lockedPackages[name], `unlocked dependency: ${name}`);
    assert.equal(installed.version, lockedPackages[name].version, name);
    assert.equal(installed.integrity, lockedPackages[name].integrity, name);
    assert.ok(!lockedPackages[name].optional, `optional dependency installed: ${name}`);
    assert.ok(!installed.link, `workspace dependency linked: ${name}`);
  }
  await inspectBundle(bundle);
  assert.equal(await readFile(path.join(fixture, "package.json"), "utf8"), workspaceManifest);
  assert.equal(await readFile(path.join(fixture, "package-lock.json"), "utf8"), workspaceLock);
  assert.equal(await readFile(path.join(env.TARGET_BUILD_DIR, env.CONTENTS_FOLDER_PATH, "Helpers/node"), "utf8"), "node-packaging-stub");
  const npmCall = await readFile(env.NPM_CALL_LOG, "utf8").catch(error => {
    assert.fail(`packaging must invoke the npm wrapper selected by PATH: ${error.message}`);
  });
  const [installDirectory, ...npmArgs] = npmCall.trim().split("\n");
  assert.ok(!installDirectory.startsWith(`${fixture}${path.sep}`), "npm install ran inside the workspace");
  assert.deepEqual(npmArgs, ["ci", "--omit=dev", "--omit=optional", "--ignore-scripts", "--workspaces=false"]);
  await assert.rejects(access(installDirectory), { code: "ENOENT" });
});
