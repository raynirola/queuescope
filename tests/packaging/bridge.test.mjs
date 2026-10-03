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
  assert.deepEqual(manifest.dependencies, { bullmq: "5.77.0" });
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
  const [installDirectory, ...npmArgs] = (await readFile(env.NPM_CALL_LOG, "utf8")).trim().split("\n");
  assert.ok(!installDirectory.startsWith(`${fixture}${path.sep}`), "npm install ran inside the workspace");
  assert.deepEqual(npmArgs, ["ci", "--omit=dev", "--omit=optional", "--ignore-scripts", "--workspaces=false"]);
  await assert.rejects(access(installDirectory), { code: "ENOENT" });
});
