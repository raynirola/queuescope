#!/usr/bin/env node
// Consumer-boundary checks: real npm tarballs, outside the workspace, with the
// actual server-only package and Next.js compiler. No mocked imports or Redis.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, realpathSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { setTimeout as delay } from 'node:timers/promises';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const temporary = mkdtempSync(join(tmpdir(), 'queuescope-packages-'));
const consumer = join(temporary, 'consumer');
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const env = { ...process.env, NEXT_TELEMETRY_DISABLED: '1', NODE_ENV: 'production' };
// A root NODE_OPTIONS=--conditions=react-server would hide the boundary guard.
delete env.NODE_OPTIONS;
function run(command, args, cwd = consumer) {
  return execFileSync(command, args, { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180_000 });
}
function file(path, contents) { writeFileSync(join(consumer, path), contents); }
function build() {
  return spawnSync(process.execPath, ['node_modules/next/dist/bin/next', 'build', '--webpack'], {
    cwd: consumer, env, encoding: 'utf8', timeout: 180_000,
  });
}
try {
  mkdirSync(consumer);
  const nodePack = JSON.parse(run(npm, ['pack', './packages/node', '--json', '--pack-destination', temporary, '--ignore-scripts'], root))[0];
  const nextPack = JSON.parse(run(npm, ['pack', './packages/next', '--json', '--pack-destination', temporary, '--ignore-scripts'], root))[0];
  for (const packed of [nodePack, nextPack]) {
    assert(!packed.files.some(({ path }) => path.includes('node_modules/') || path.endsWith('.test.mjs')));
  }
  const dev = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).devDependencies;
  file('package.json', JSON.stringify({ name: 'queuescope-consumer-check', private: true, type: 'module' }));
  process.stdout.write('Installing packed adapters in an isolated consumer...\n');
  run(npm, ['install', '--ignore-scripts', '--no-audit', '--no-fund', '--save-exact',
    join(temporary, nodePack.filename), join(temporary, nextPack.filename),
    ...['next', 'react', 'react-dom', 'typescript', '@types/node', 'bullmq'].map((name) => `${name}@${dev[name]}`)]);
  for (const name of ['node', 'next']) {
    assert(realpathSync(join(consumer, 'node_modules/@queuescope', name)).startsWith(consumer));
  }
  file('smoke.mjs', `import assert from 'node:assert/strict';
import { createQueueCatalog, serializeQueueCatalog } from '@queuescope/node';
const queue = {name: 'mail', opts: {prefix: 'app:队列', get connection(){throw Error('secret access')}}};
const result = JSON.parse(serializeQueueCatalog(createQueueCatalog([{queue, displayName:'Mail'}])));
assert.equal(result.queues[0].prefix, 'app:队列');
assert(!JSON.stringify(result).includes('connection'));
`);
  run(process.execPath, ['smoke.mjs']);
  file('next-smoke.mjs', `import assert from 'node:assert/strict';
import {createQueueCatalog, serializeQueueCatalog} from '@queuescope/next';
assert.equal(JSON.parse(serializeQueueCatalog(createQueueCatalog([{name:'mail',prefix:'bull'}]))).queues.length,1);
`);
  run(process.execPath, ['--conditions=react-server', 'next-smoke.mjs']);
  const poisoned = spawnSync(process.execPath, ['next-smoke.mjs'], { cwd: consumer, env, encoding: 'utf8' });
  assert.notEqual(poisoned.status, 0);
  assert.match(poisoned.stderr, /cannot be imported from a Client Component/);
  file('consumer.mts', `import { Queue } from 'bullmq';
import { createQueueCatalog, serializeQueueCatalog, type QueueCatalog } from '@queuescope/node';
import { writeQueueCatalogFile } from '@queuescope/next';
declare const queue: Queue<{message: string}, number, 'send'>;
const catalog: QueueCatalog = createQueueCatalog([{queue,displayName:'Mail'}, {name:'未启动',prefix:'app:队列'}]);
serializeQueueCatalog(catalog);
void writeQueueCatalogFile('/tmp/explicit-catalog.json',catalog);
// @ts-expect-error credentials are never a registration field
createQueueCatalog([{name:'mail',prefix:'bull',password:'secret'}]);
`);
  run(process.execPath, ['node_modules/typescript/bin/tsc', '--noEmit', '--strict', '--skipLibCheck', '--target', 'ES2022', '--module', 'NodeNext', '--moduleResolution', 'NodeNext', 'consumer.mts']);
  mkdirSync(join(consumer, 'app'));
  file('next.config.mjs', 'export default { experimental: { cpus: 1 } };\n');
  file('app/layout.js', "export default function Layout({children}) { return <html><body>{children}</body></html>; }\n");
  file('instrumentation.js', `export async function register() {
    if (process.env.NODE_ENV !== 'development' || process.env.NEXT_RUNTIME !== 'nodejs' || !process.env.QUEUESCOPE_EXPORT_PATH) return;
    const {createQueueCatalog,writeQueueCatalogFile} = await import('@queuescope/next');
    await writeQueueCatalogFile(process.env.QUEUESCOPE_EXPORT_PATH,createQueueCatalog([{name:'mail',prefix:'bull'}]));
  }
`);
  file('app/page.js', `import {createQueueCatalog, serializeQueueCatalog} from '@queuescope/next';
export const runtime = 'nodejs';
export default function Page() {
  const catalog = createQueueCatalog([{name:'mail',prefix:'bull'}]);
  return <p>{JSON.parse(serializeQueueCatalog(catalog)).queues.length} queue</p>;
}
`);
  process.stdout.write('Building a production Next.js Server Component with packed adapters...\n');
  let result = build();
  assert.equal(result.status, 0, `Server build failed:\n${result.stdout}\n${result.stderr}`);
  assert(!existsSync(join(consumer, 'catalog.json')), 'Production build wrote a catalog.');
  process.stdout.write('Checking opt-in development instrumentation with the packed adapter...\n');
  const reservation = createServer();
  await new Promise((resolve, reject) => { reservation.once('error', reject); reservation.listen(0, '127.0.0.1', resolve); });
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  const developmentOutput = join(temporary, 'development-catalog.json');
  let logs = '';
  const server = spawn(process.execPath, ['node_modules/next/dist/bin/next', 'dev', '--webpack', '--hostname', '127.0.0.1', '--port', String(port)], {
    cwd: consumer, env: { ...env, NODE_ENV: 'development', QUEUESCOPE_EXPORT_PATH: developmentOutput },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.on('data', (data) => { logs = (logs + data).slice(-32_768); });
  server.stderr.on('data', (data) => { logs = (logs + data).slice(-32_768); });
  try {
    const deadline = Date.now() + 60_000;
    while (!existsSync(developmentOutput) && server.exitCode === null && Date.now() < deadline) await delay(100);
    assert(existsSync(developmentOutput), `Development instrumentation did not export: ${logs}`);
    assert.equal(JSON.parse(readFileSync(developmentOutput, 'utf8')).queues[0].name, 'mail');
  } finally {
    server.kill('SIGTERM');
    const deadline = Date.now() + 10_000;
    while (server.exitCode === null && server.signalCode === null && Date.now() < deadline) await delay(100);
    if (server.exitCode === null && server.signalCode === null) server.kill('SIGKILL');
  }
  rmSync(join(consumer, '.next'), { recursive: true, force: true });
  file('app/page.js', `'use client';
import {createQueueCatalog} from '@queuescope/next';
export default function Page() { return <p>{createQueueCatalog([{name:'mail',prefix:'bull'}]).queues.length}</p>; }
`);
  process.stdout.write('Verifying Next.js rejects the same package from a Client Component...\n');
  result = build();
  assert.notEqual(result.status, 0, 'Client import unexpectedly compiled.');
  assert.match(`${result.stdout}\n${result.stderr}`, /server-only|Server Component/);
  process.stdout.write('Packed Node + Next.js consumption, TypeScript, production build, and client rejection passed.\n');
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
