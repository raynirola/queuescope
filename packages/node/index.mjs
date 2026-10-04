import { Buffer } from 'node:buffer';

/** Limits shared with the native QueueScope importer. All sizes are UTF-8 bytes. */
export const QUEUE_CATALOG_LIMITS = Object.freeze({
  maxBytes: 1024 * 1024,
  maxQueues: 1000,
  maxIdentifierBytes: 512,
  maxLabelBytes: 256,
});

const SCHEMA = 'queuescope.queue-catalog';
const VERSION = 1;
const ENTRY_FIELDS = new Set(['name', 'prefix', 'displayName', 'group']);
const REGISTRATION_FIELDS = new Set(['queue', 'displayName', 'group']);
const CATALOG_FIELDS = new Set(['schema', 'version', 'queues']);
const CONTROLS = /[\u0000-\u001f\u007f-\u009f]/u;
const EDGE_WHITESPACE = /^[\p{White_Space}\uFEFF]|[\p{White_Space}\uFEFF]$/u;
const VALIDATION_ERRORS = new WeakSet();
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u;

/** Validation errors never include supplied values or underlying getter errors. */
export class QueueCatalogError extends TypeError {
  constructor(message) {
    super(message);
    this.name = 'QueueCatalogError';
    this.code = 'ERR_QUEUE_CATALOG';
  }
}

function fail(message) {
  const error = new QueueCatalogError(message);
  VALIDATION_ERRORS.add(error);
  throw error;
}

function safely(operation) {
  try {
    return operation();
  } catch (error) {
    if (VALIDATION_ERRORS.has(error)) throw error;
    // Proxies and queue identity getters can throw arbitrary secret-bearing errors.
    fail('Could not read queue catalog input.');
  }
}

function fields(value, allowed, required, path) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${path} must be a plain object.`);
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) {
    fail(`${path} must be a plain object.`);
  }
  const result = Object.create(null);
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string' || !allowed.has(key)) {
      // Do not echo an unknown key: even a key may contain a credential.
      fail(`${path} contains an unknown field.`);
    }
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) {
      fail(`${path} fields must be data properties.`);
    }
    result[key] = descriptor.value;
  }
  for (const key of required) {
    if (!Object.hasOwn(result, key)) fail(`${path}.${key} is required.`);
  }
  return result;
}

function string(value, maxBytes, path, queueName = false) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(`${path} must be a nonempty string.`);
  }
  if (CONTROLS.test(value) || EDGE_WHITESPACE.test(value) || LONE_SURROGATE.test(value)) {
    fail(`${path} contains invalid whitespace, control characters, or Unicode.`);
  }
  if (queueName && value.includes(':')) fail(`${path} must not contain a colon.`);
  if (Buffer.byteLength(value, 'utf8') > maxBytes) {
    fail(`${path} exceeds its UTF-8 byte limit.`);
  }
  return value;
}

function entry(source, path) {
  const output = {
    name: string(source.name, QUEUE_CATALOG_LIMITS.maxIdentifierBytes, `${path}.name`, true),
    prefix: string(source.prefix, QUEUE_CATALOG_LIMITS.maxIdentifierBytes, `${path}.prefix`),
  };
  for (const key of ['displayName', 'group']) {
    if (Object.hasOwn(source, key)) {
      output[key] = string(source[key], QUEUE_CATALOG_LIMITS.maxLabelBytes, `${path}.${key}`);
    }
  }
  return Object.freeze(output);
}

function arrayEntries(value, path, transform) {
  if (!Array.isArray(value)) fail(`${path} must be an array.`);
  if (value.length > QUEUE_CATALOG_LIMITS.maxQueues) {
    fail(`${path} exceeds the maximum number of queues.`);
  }
  // Reject sparse arrays, accessors, and custom properties without executing them.
  const length = value.length;
  if (Reflect.ownKeys(value).length !== length + 1) {
    fail(`${path} must be a dense array without extra properties.`);
  }
  const output = [];
  const seen = new Set();
  for (let index = 0; index < length; index += 1) {
    const descriptor = Object.getOwnPropertyDescriptor(value, String(index));
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) {
      fail(`${path} must be a dense array of data properties.`);
    }
    const result = transform(descriptor.value, `${path}[${index}]`);
    const identity = JSON.stringify([result.prefix, result.name]);
    if (seen.has(identity)) fail(`${path} contains a duplicate queue identity.`);
    seen.add(identity);
    output.push(result);
  }
  return Object.freeze(output);
}

function boundedCatalog(queues) {
  const catalog = Object.freeze({ schema: SCHEMA, version: VERSION, queues });
  if (Buffer.byteLength(JSON.stringify(catalog), 'utf8') > QUEUE_CATALOG_LIMITS.maxBytes) {
    fail('The serialized queue catalog exceeds the maximum UTF-8 byte size.');
  }
  return catalog;
}

function registration(value, path) {
  // The registration wrapper is ours, not the BullMQ Queue instance. Never
  // enumerate, spread, serialize, or inspect a Queue or its options object.
  const hasQueue = value !== null && typeof value === 'object' && Object.hasOwn(value, 'queue');
  if (!hasQueue) return entry(fields(value, ENTRY_FIELDS, ['name', 'prefix'], path), path);
  const source = fields(value, REGISTRATION_FIELDS, ['queue'], path);
  const queue = source.queue;
  if (queue === null || typeof queue !== 'object') fail(`${path}.queue must be a queue instance.`);
  // These are the only properties read from the registered Queue and opts.
  const name = queue.name;
  const opts = queue.opts;
  if (opts === null || typeof opts !== 'object') fail(`${path}.queue.opts must be an object.`);
  const prefix = opts.prefix;
  const identity = { name, prefix: prefix === undefined ? 'bull' : prefix };
  for (const key of ['displayName', 'group']) {
    if (Object.hasOwn(source, key)) identity[key] = source[key];
  }
  return entry(identity, path);
}

/**
 * Snapshot explicitly registered Queue instances or queue definitions.
 * Does not instantiate queues, discover Redis keys, or access clients/connections.
 */
export function createQueueCatalog(registrations) {
  return safely(() => boundedCatalog(arrayEntries(registrations, 'registrations', registration)));
}

/** Revalidate a catalog and serialize only its versioned, whitelisted fields. */
export function serializeQueueCatalog(catalog) {
  return safely(() => {
    const source = fields(catalog, CATALOG_FIELDS, ['schema', 'version', 'queues'], 'catalog');
    if (source.schema !== SCHEMA) fail('catalog.schema is not supported.');
    if (source.version !== VERSION) fail('catalog.version is not supported.');
    const queues = arrayEntries(source.queues, 'catalog.queues', (value, path) =>
      entry(fields(value, ENTRY_FIELDS, ['name', 'prefix'], path), path));
    return JSON.stringify(boundedCatalog(queues));
  });
}
