import { Queue } from 'bullmq';
import {
  createQueueCatalog,
  serializeQueueCatalog,
  QueueCatalogError,
  QUEUE_CATALOG_LIMITS,
  type QueueCatalog,
  type QueueCatalogEntry,
  type QueueRegistration,
  type RegisteredQueue,
} from '@queuescope/node';

// Compile-only: this file is never executed, so no Redis clients are created.
declare const queue: Queue;
const structurallyCompatible: RegisteredQueue = queue;
const registrations: readonly QueueRegistration[] = [
  { queue: structurallyCompatible, displayName: 'Email' },
  { name: 'reports', prefix: 'team:prod', group: 'Reporting' },
] as const;
const value: QueueCatalog = createQueueCatalog(registrations);
const output: string = serializeQueueCatalog(value);
const entry: QueueCatalogEntry | undefined = value.queues[0];
const maximum: 1048576 = QUEUE_CATALOG_LIMITS.maxBytes;
const errorCode: 'ERR_QUEUE_CATALOG' = new QueueCatalogError('invalid').code;
void [output, entry, maximum, errorCode];

// @ts-expect-error Explicit definitions require a prefix.
createQueueCatalog([{ name: 'missing-prefix' }]);
// @ts-expect-error Registrations cannot mix a Queue with explicit identity fields.
createQueueCatalog([{ queue, prefix: 'bull' }]);
// @ts-expect-error Connection options are outside the catalog schema.
createQueueCatalog([{ name: 'jobs', prefix: 'bull', connection: {} }]);
// @ts-expect-error Only catalog version 1 is supported.
serializeQueueCatalog({ schema: 'queuescope.queue-catalog', version: 2, queues: [] });
// @ts-expect-error Catalog snapshots are readonly.
value.queues.push({ name: 'jobs', prefix: 'bull' });
