import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Queue } from 'bullmq';
import {
  createQueueCatalog,
  serializeQueueCatalog,
  QueueCatalogError,
  QUEUE_CATALOG_LIMITS,
} from './index.mjs';

const base = () => ({ name: 'emails', prefix: 'team:prod' });
const catalog = (queues = [base()]) => ({ schema: 'queuescope.queue-catalog', version: 1, queues });
const fixture = async (name) => JSON.parse(await readFile(new URL(`../../tests/catalog/${name}`, import.meta.url), 'utf8'));
const invalid = (operation, pattern) => assert.throws(operation, (error) => {
  assert.ok(error instanceof QueueCatalogError);
  assert.equal(error.code, 'ERR_QUEUE_CATALOG');
  if (pattern) assert.match(error.message, pattern);
  return true;
});

test('creates an immutable identity-only snapshot from definitions and queue instances', () => {
  const queue = { name: 'emails', opts: { prefix: 'team:prod' } };
  const definition = { name: 'reports', prefix: 'team:prod', displayName: 'Reports', group: 'Operations' };
  const result = createQueueCatalog([{ queue, displayName: 'Email' }, definition]);
  assert.deepEqual(result, catalog([
    { ...base(), displayName: 'Email' },
    definition,
  ]));
  assert.ok(Object.isFrozen(result));
  assert.ok(Object.isFrozen(result.queues));
  assert.ok(result.queues.every(Object.isFrozen));
  queue.name = 'changed';
  definition.group = 'changed';
  assert.equal(result.queues[0].name, 'emails');
  assert.equal(result.queues[1].group, 'Operations');
  assert.throws(() => result.queues.push(base()), TypeError);
  assert.deepEqual(JSON.parse(serializeQueueCatalog(result)), result);
});

test('reads exactly name, opts, and prefix without inspecting secrets or invoking methods', () => {
  const calls = [];
  const secret = 'redis://private-user:private-password@secret.internal:6379';
  const opts = new Proxy({ prefix: 'app:jobs' }, {
    get(target, key) {
      calls.push(`opts.${String(key)}`);
      if (key !== 'prefix') throw new Error(secret);
      return target[key];
    },
    ownKeys() { throw new Error(secret); },
    getOwnPropertyDescriptor() { throw new Error(secret); },
    getPrototypeOf() { throw new Error(secret); },
  });
  const queue = new Proxy({ name: 'receipts', opts }, {
    get(target, key) {
      calls.push(`queue.${String(key)}`);
      if (!['name', 'opts'].includes(key)) throw new Error(secret);
      return target[key];
    },
    ownKeys() { throw new Error(secret); },
    getOwnPropertyDescriptor() { throw new Error(secret); },
    getPrototypeOf() { throw new Error(secret); },
  });
  const json = serializeQueueCatalog(createQueueCatalog([{ queue }]));
  assert.deepEqual(calls, ['queue.name', 'queue.opts', 'opts.prefix']);
  assert.equal(json, '{"schema":"queuescope.queue-catalog","version":1,"queues":[{"name":"receipts","prefix":"app:jobs"}]}');
  assert.ok(!json.includes(secret));
});

test('never visits circular and secret-bearing queue options or connection/client getters', () => {
  const opts = { prefix: 'bull', password: 'secret-password', tls: { key: 'secret-key' } };
  opts.self = opts;
  let touched = 0;
  const forbidden = () => { touched += 1; throw new Error('secret-connection'); };
  Object.defineProperties(opts, {
    connection: { enumerable: true, get: forbidden },
    toJSON: { enumerable: true, get: forbidden },
  });
  const queue = { name: 'jobs', opts, add: forbidden, getJobCounts: forbidden, close: forbidden };
  Object.defineProperties(queue, {
    connection: { get: forbidden },
    client: { get: forbidden },
    toJSON: { get: forbidden },
  });
  assert.deepEqual(createQueueCatalog([{ queue }]).queues, [{ name: 'jobs', prefix: 'bull' }]);
  assert.equal(touched, 0);
});

test('supports a real BullMQ 5.77 Queue without connecting or updating metadata', async (t) => {
  // BullMQ itself can normally connect/write on construction. These flags isolate
  // the real shape without a Redis server and are test setup, not adapter behavior.
  const queue = new Queue('実際のキュー', {
    prefix: 'team:prod',
    connection: { lazyConnect: true, host: '127.0.0.1', port: 1, password: 'fixture-secret' },
    skipWaitingForReady: true,
    skipVersionCheck: true,
    skipMetasUpdate: true,
  });
  const connection = queue.connection;
  t.after(() => connection.close(true));
  const client = await queue.client;
  assert.equal(client.status, 'wait');
  const forbidden = () => { throw new Error('adapter must never read a connection or client'); };
  Object.defineProperty(queue.opts, 'connection', { get: forbidden });
  Object.defineProperty(queue, 'connection', { get: forbidden });
  Object.defineProperty(queue, 'client', { get: forbidden });
  const result = createQueueCatalog([{ queue, group: '日本語' }]);
  assert.deepEqual(result.queues, [{ name: '実際のキュー', prefix: 'team:prod', group: '日本語' }]);
  assert.equal(client.status, 'wait');
});

test('defaults only an undefined queue prefix to bull', () => {
  assert.equal(createQueueCatalog([{ queue: { name: 'jobs', opts: {} } }]).queues[0].prefix, 'bull');
  for (const prefix of [null, '', 0, false]) {
    invalid(() => createQueueCatalog([{ queue: { name: 'jobs', opts: { prefix } } }]));
  }
  invalid(() => createQueueCatalog([{ name: 'jobs' }]));
  invalid(() => createQueueCatalog([{ queue: { name: 'jobs' } }]));
  invalid(() => createQueueCatalog([{ queue: null }]));
});

test('sanitizes unexpected getter/proxy exceptions, including forged public error instances', () => {
  for (const thrown of [new Error('secret-token'), new QueueCatalogError('secret-token'), 'secret-token', null]) {
    const queue = { get name() { throw thrown; } };
    assert.throws(() => createQueueCatalog([{ queue }]), (error) => {
      assert.equal(error.message, 'Could not read queue catalog input.');
      assert.equal(error.cause, undefined);
      assert.ok(!error.stack.includes('secret-token'));
      return true;
    });
  }
  const input = new Proxy({}, { getPrototypeOf() { throw new Error('secret-token'); } });
  invalid(() => createQueueCatalog([input]), /Could not read/);
});

test('supports empty catalogs and null-prototype definition objects', () => {
  assert.deepEqual(createQueueCatalog([]), catalog([]));
  assert.equal(serializeQueueCatalog(catalog([])), '{"schema":"queuescope.queue-catalog","version":1,"queues":[]}');
  const definition = Object.assign(Object.create(null), base());
  assert.deepEqual(createQueueCatalog([definition]).queues, [base()]);
});

test('preserves Unicode, internal spaces, colons in prefixes, and registration order', () => {
  const input = [
    { name: '通知📨', prefix: 'team:prod:日本', displayName: '通知 🚀', group: '顧客' },
    { name: 'café', prefix: 'bull' },
    { name: 'cafe\u0301', prefix: 'bull' },
    { name: 'two words', prefix: 'space inside' },
  ];
  assert.deepEqual(createQueueCatalog(input).queues, input);
  assert.equal(JSON.parse(serializeQueueCatalog(createQueueCatalog(input))).queues[2].name, 'cafe\u0301');
});

test('rejects duplicate identities, but permits the same name under different prefixes', () => {
  invalid(() => createQueueCatalog([base(), { ...base(), displayName: 'Another' }]), /duplicate/);
  invalid(() => serializeQueueCatalog(catalog([base(), base()])), /duplicate/);
  const input = [{ name: 'emails', prefix: 'a:b' }, { name: 'emails', prefix: 'a' }];
  assert.deepEqual(createQueueCatalog(input).queues, input);
});

test('accepts exact identifier and label byte limits, including multibyte Unicode', () => {
  const definition = {
    name: '😀'.repeat(128),
    prefix: 'é'.repeat(256),
    displayName: '😀'.repeat(64),
    group: 'é'.repeat(128),
  };
  assert.deepEqual(createQueueCatalog([definition]).queues, [definition]);
  for (const key of ['name', 'prefix', 'displayName', 'group']) {
    invalid(() => createQueueCatalog([{ ...definition, [key]: definition[key] + 'x' }]), /UTF-8 byte limit/);
    invalid(() => serializeQueueCatalog(catalog([{ ...definition, [key]: definition[key] + 'x' }])));
  }
});

test('enforces 1000-queue limit before touching queue contents', () => {
  const input = Array.from({ length: 1000 }, (_, index) => ({ name: `q${index}`, prefix: 'bull' }));
  assert.equal(createQueueCatalog(input).queues.length, 1000);
  const tooMany = Array(1001);
  Object.defineProperty(tooMany, '0', { get() { assert.fail('must reject count before data reads'); } });
  invalid(() => createQueueCatalog(tooMany), /maximum number/);
  invalid(() => serializeQueueCatalog(catalog(tooMany)), /maximum number/);
});

test('accepts exactly 1 MiB of compact UTF-8 JSON and rejects one more byte', () => {
  const input = Array.from({ length: 1000 }, (_, index) => ({
    name: String(index).padStart(512, 'n'), prefix: 'p'.repeat(512),
  }));
  // Base compact JSON is 1,048,060 bytes. Two displayName fields add 34 bytes
  // of syntax plus 482 bytes of text, reaching exactly 1,048,576 bytes.
  input[0].displayName = 'd'.repeat(256);
  input[1].displayName = 'd'.repeat(226);
  const size = (value) => Buffer.byteLength(JSON.stringify(value), 'utf8');
  assert.equal(size(catalog(input)), QUEUE_CATALOG_LIMITS.maxBytes);
  assert.equal(Buffer.byteLength(serializeQueueCatalog(createQueueCatalog(input))), QUEUE_CATALOG_LIMITS.maxBytes);
  input[1].displayName += 'd';
  invalid(() => createQueueCatalog(input), /maximum UTF-8 byte size/);
  invalid(() => serializeQueueCatalog(catalog(input)), /maximum UTF-8 byte size/);
});

test('measures serialized escaping as bytes, not only raw field lengths', () => {
  const input = Array.from({ length: 1000 }, (_, index) => ({
    name: String(index).padStart(512, '"'), prefix: '\\'.repeat(512),
  }));
  invalid(() => createQueueCatalog(input), /maximum UTF-8 byte size/);
});

for (const key of ['name', 'prefix', 'displayName', 'group']) {
  test(`rejects missing-value and malformed ${key} fields without coercion`, () => {
    for (const value of ['', undefined, null, 1, true, {}, [], new String('value')]) {
      invalid(() => createQueueCatalog([{ ...base(), [key]: value }]));
      invalid(() => serializeQueueCatalog(catalog([{ ...base(), [key]: value }])));
    }
    for (const value of [' leading', 'trailing ', '\tvalue', 'value\n', '\u00a0value', 'value\u2007', '\u2028value', 'value\u3000', '\ufeffvalue', 'value\ufeff', 'in\u0000side', 'in\u001fside', 'in\u007fside', 'in\u0085side', 'in\u009fside', 'bad\ud800', 'bad\udfff']) {
      invalid(() => createQueueCatalog([{ ...base(), [key]: value }]), /invalid whitespace/);
    }
  });
}

test('rejects colon names and does not silently trim strings', () => {
  invalid(() => createQueueCatalog([{ name: 'bad:name', prefix: 'bull' }]), /colon/);
  invalid(() => createQueueCatalog([{ name: 'emails ', prefix: 'bull' }]));
  invalid(() => createQueueCatalog([{ name: 'emails', prefix: ' bull' }]));
});

test('rejects unknown fields at every object boundary without invoking their getters', () => {
  const secretKey = 'secret-password-key';
  const objects = [
    () => createQueueCatalog([{ ...base(), [secretKey]: 'secret-password-value' }]),
    () => createQueueCatalog([{ queue: { name: 'jobs', opts: {} }, prefix: 'bull' }]),
    () => createQueueCatalog([{ queue: { name: 'jobs', opts: {} }, connection: {} }]),
    () => serializeQueueCatalog({ ...catalog(), connection: {} }),
    () => serializeQueueCatalog(catalog([{ ...base(), connection: {} }])),
    () => serializeQueueCatalog({ ...catalog(), [Symbol('secret')]: 'secret' }),
  ];
  for (const operation of objects) {
    assert.throws(operation, (error) => {
      assert.ok(error instanceof QueueCatalogError);
      assert.match(error.message, /unknown field/);
      assert.ok(!error.message.includes('secret'));
      return true;
    });
  }
  const definition = base();
  Object.defineProperty(definition, 'connection', { enumerable: true, get() { assert.fail('do not execute'); } });
  invalid(() => createQueueCatalog([definition]), /unknown field/);
});

test('rejects accessor registration/catalog fields and toJSON hooks without executing them', () => {
  for (const [object, key, operation] of [
    [base(), 'name', (value) => createQueueCatalog([value])],
    [{ queue: {} }, 'queue', (value) => createQueueCatalog([value])],
    [catalog(), 'queues', serializeQueueCatalog],
  ]) {
    Object.defineProperty(object, key, { enumerable: true, get() { assert.fail('accessor called'); } });
    invalid(() => operation(object), /data properties/);
  }
  const object = { ...catalog(), toJSON() { assert.fail('toJSON called'); } };
  invalid(() => serializeQueueCatalog(object), /unknown field/);
});

test('rejects malformed arrays, extra properties and accessor elements without executing them', () => {
  for (const value of [null, {}, 'queues', 2, undefined]) {
    invalid(() => createQueueCatalog(value), /array/);
    invalid(() => serializeQueueCatalog({ ...catalog(), queues: value }), /array/);
  }
  for (const value of [[, base()], Object.assign([base()], { connection: 'secret' })]) {
    invalid(() => createQueueCatalog(value), /dense array/);
  }
  const input = [base()];
  Object.defineProperty(input, '0', { get() { assert.fail('array getter called'); } });
  invalid(() => createQueueCatalog(input), /data properties/);
  const jsonHook = Object.assign([base()], { toJSON() { assert.fail('array toJSON called'); } });
  invalid(() => serializeQueueCatalog(catalog(jsonHook)), /dense array/);
});

test('strictly validates schema, version, required fields, and object types', () => {
  for (const value of [null, undefined, [], 'catalog', new Date()]) invalid(() => serializeQueueCatalog(value));
  for (const key of ['schema', 'version', 'queues']) {
    const object = catalog();
    delete object[key];
    invalid(() => serializeQueueCatalog(object), /required/);
  }
  for (const schema of ['', 'other', 1, null]) invalid(() => serializeQueueCatalog({ ...catalog(), schema }), /schema/);
  for (const version of [0, 2, '1', null, NaN]) invalid(() => serializeQueueCatalog({ ...catalog(), version }), /version/);
  for (const entry of [null, [], 'queue', new Date(), {}]) invalid(() => createQueueCatalog([entry]));
  class Definition { constructor() { Object.assign(this, base()); } }
  invalid(() => createQueueCatalog([new Definition()]), /plain object/);
});

test('shared cross-language valid fixtures preserve exact values and reject invalid fixtures', async () => {
  for (const name of ['valid-v1.json', 'empty-v1.json', 'mixed-prefix-v1.json']) {
    const data = await fixture(name);
    assert.deepEqual(JSON.parse(serializeQueueCatalog(data)), data);
    assert.deepEqual(createQueueCatalog(data.queues), data);
  }
  for (const name of ['duplicate-v1.json', 'unknown-fields-v1.json', 'unsupported-version.json', 'invalid-name-v1.json', 'invalid-whitespace-v1.json', 'invalid-control-v1.json']) {
    const data = await fixture(name);
    invalid(() => serializeQueueCatalog(data));
  }
});

test('malformed fixture is not parseable JSON', async () => {
  const text = await readFile(new URL('../../tests/catalog/malformed.json', import.meta.url), 'utf8');
  assert.throws(() => JSON.parse(text), SyntaxError);
});
