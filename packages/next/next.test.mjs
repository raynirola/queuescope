import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm, symlink, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createQueueCatalog, serializeQueueCatalog, writeQueueCatalogFile } from './index.mjs';

const registrations = [{ name: '邮件', prefix: 'app:队列', displayName: 'Mail', group: 'Core' }];

test('production server API is explicit and credential-free', () => {
  const previous = process.env.NODE_ENV;
  process.env.NODE_ENV = 'production';
  try {
    const catalog = createQueueCatalog(registrations);
    assert.equal(JSON.parse(serializeQueueCatalog(catalog)).queues[0].prefix, 'app:队列');
  } finally {
    if (previous === undefined) delete process.env.NODE_ENV;
    else process.env.NODE_ENV = previous;
  }
});

test('Edge runtime is rejected instead of advertised as supported', () => {
  const previous = process.env.NEXT_RUNTIME;
  process.env.NEXT_RUNTIME = 'edge';
  try { assert.throws(() => createQueueCatalog(registrations), /Node.js server runtime/); }
  finally {
    if (previous === undefined) delete process.env.NEXT_RUNTIME;
    else process.env.NEXT_RUNTIME = previous;
  }
});

test('default Node resolution hits the real server-only package guard', () => {
  const child = spawnSync(process.execPath, ['--input-type=module', '-e', "await import('@queuescope/next')"], { encoding: 'utf8' });
  assert.notEqual(child.status, 0);
  assert.match(child.stderr, /cannot be imported from a Client Component/);
});

test('explicit file export is complete, private, exclusive and cleans staging', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'queuescope-next-'));
  try {
    const catalog = createQueueCatalog(registrations);
    const output = join(dir, 'catalog.json');
    assert.deepEqual(await readdir(dir), []);
    assert.equal(await writeQueueCatalogFile(output, catalog), output);
    assert.deepEqual(JSON.parse(await readFile(output, 'utf8')), catalog);
    if (process.platform !== 'win32') assert.equal((await stat(output)).mode & 0o777, 0o600);
    await assert.rejects(writeQueueCatalogFile(output, catalog), { code: 'EEXIST' });
    assert.deepEqual(await readdir(dir), ['catalog.json']);
    await symlink(output, join(dir, 'link.json'));
    await assert.rejects(writeQueueCatalogFile(join(dir, 'link.json'), catalog), { code: 'EEXIST' });
    assert.deepEqual(JSON.parse(await readFile(output, 'utf8')), catalog);
    assert.deepEqual((await readdir(dir)).sort(), ['catalog.json', 'link.json']);
  } finally { await rm(dir, { recursive: true, force: true }); }
});

test('invalid catalog and implicit paths produce no filesystem output', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'queuescope-next-'));
  try {
    await assert.rejects(writeQueueCatalogFile('catalog.json', createQueueCatalog(registrations)), /absolute/);
    await assert.rejects(writeQueueCatalogFile(join(dir, 'bad.json'), { schema: 'wrong', version: 1, queues: [] }));
    assert.deepEqual(await readdir(dir), []);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
