/** A minimal structural interface; no BullMQ runtime dependency is required. */
export interface RegisteredQueue {
  readonly name: string;
  readonly opts: { readonly prefix?: string };
}

export interface QueueCatalogEntry {
  readonly name: string;
  readonly prefix: string;
  readonly displayName?: string;
  readonly group?: string;
}

export interface QueueInstanceRegistration {
  readonly queue: RegisteredQueue;
  readonly displayName?: string;
  readonly group?: string;
  readonly name?: never;
  readonly prefix?: never;
}

export interface QueueDefinitionRegistration extends QueueCatalogEntry {
  readonly queue?: never;
}

export type QueueRegistration = QueueInstanceRegistration | QueueDefinitionRegistration;

export interface QueueCatalog {
  readonly schema: 'queuescope.queue-catalog';
  readonly version: 1;
  readonly queues: readonly QueueCatalogEntry[];
}

export declare const QUEUE_CATALOG_LIMITS: Readonly<{
  maxBytes: 1048576;
  maxQueues: 1000;
  maxIdentifierBytes: 512;
  maxLabelBytes: 256;
}>;

/** Validation failures contain field paths, never supplied field values. */
export declare class QueueCatalogError extends TypeError {
  readonly code: 'ERR_QUEUE_CATALOG';
  constructor(message: string);
}

/**
 * Create a frozen identity-only snapshot in registration order. Duplicate
 * (prefix, name) pairs and unknown registration fields are rejected.
 * Queue instances are read only at name and opts.prefix. An undefined prefix
 * uses BullMQ's default "bull". No Redis connection or queue method is accessed.
 */
export declare function createQueueCatalog(registrations: readonly QueueRegistration[]): QueueCatalog;

/** Validate and serialize a version-1 catalog, enforcing the 1 MiB byte limit. */
export declare function serializeQueueCatalog(catalog: QueueCatalog): string;
