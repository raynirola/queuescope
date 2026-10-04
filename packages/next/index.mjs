// Next.js rejects imports of this entry point from Client Components.
import 'server-only';
import { isAbsolute, dirname, join } from 'node:path';
import { mkdtemp, writeFile, link, rm } from 'node:fs/promises';
import {
  createQueueCatalog as createCatalog,
  serializeQueueCatalog as serializeCatalog,
} from '@queuescope/node';
export { QueueCatalogError, QUEUE_CATALOG_LIMITS } from '@queuescope/node';

function assertNodeRuntime() {
  if (typeof process === 'undefined' || !process.versions?.node || process.env.NEXT_RUNTIME === 'edge') {
    throw new Error('@queuescope/next requires the Next.js Node.js server runtime.');
  }
}

/** Explicit, pure metadata export. Importing this module does not export or write anything. */
export function createQueueCatalog(registrations) {
  assertNodeRuntime();
  return createCatalog(registrations);
}

export function serializeQueueCatalog(catalog) {
  assertNodeRuntime();
  return serializeCatalog(catalog);
}

/**
 * Explicit local file export. Never overwrites an existing file or follows a
 * destination symlink. The containing directory must already exist. Keep it
 * outside Next.js public/ and all other served or tracked directories.
 */
export async function writeQueueCatalogFile(outputPath, catalog) {
  assertNodeRuntime();
  if (typeof outputPath !== 'string' || !isAbsolute(outputPath)) {
    throw new TypeError('An explicit absolute output file path is required.');
  }
  // Validate before filesystem changes. No credentials or queue methods are read.
  const json = serializeCatalog(catalog);
  const temporaryDirectory = await mkdtemp(join(dirname(outputPath), '.queuescope-'));
  const temporaryFile = join(temporaryDirectory, 'catalog.json');
  try {
    await writeFile(temporaryFile, json, { encoding: 'utf8', mode: 0o600, flag: 'wx' });
    // An atomic, exclusive link exposes only the fully written file. Existing
    // destinations fail with EEXIST, including symlinks. Both files share a volume.
    await link(temporaryFile, outputPath);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
  return outputPath;
}
