import type { QueueCatalog, QueueRegistration } from '@queuescope/node';
export type { QueueCatalog, QueueRegistration } from '@queuescope/node';
export { QueueCatalogError, QUEUE_CATALOG_LIMITS } from '@queuescope/node';
/** Server-only Node.js runtime metadata serialization, without Redis access. */
export function createQueueCatalog(registrations: readonly QueueRegistration[]): QueueCatalog;
export function serializeQueueCatalog(catalog: QueueCatalog): string;
/** Explicit absolute local path; parent directory must exist; existing files are never overwritten. */
export function writeQueueCatalogFile(outputPath: string, catalog: QueueCatalog): Promise<string>;
