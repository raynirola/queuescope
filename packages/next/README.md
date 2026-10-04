# @queuescope/next

An explicit, server-only queue-catalog integration for the **Next.js App Router, Node.js runtime**. It reuses `@queuescope/node` validation and serialization, adds Next.js's `server-only` client boundary, rejects Edge execution, and offers an optional local file writer. It has no HTTP route, middleware, discovery task, global registration, or import-time export. Production use of the pure APIs is supported; there is no development-only restriction on the package.

This repository does not publish npm packages automatically. Use the npm workspaces while developing QueueScope, or install packed tarballs as described in [the adapter guide](../../docs/ADAPTERS.md). Tested with Next.js 16.3.8 and Node.js 22+; other Next.js releases have not been validated by this change.

## Pure server-side inventory

```ts
// lib/queue-catalog.ts (never import this from a Client Component)
import { createQueueCatalog, serializeQueueCatalog } from '@queuescope/next';

export function exportQueueCatalog() {
  return serializeQueueCatalog(createQueueCatalog([
    { name: 'emails', prefix: 'my-app:bull', displayName: 'Transactional email', group: 'Messaging' },
    { name: 'reports', prefix: 'my-app:bull', group: 'Analytics' },
  ]));
}
```

Calling this function returns JSON to its server-side caller. Nothing is saved, served, or transmitted automatically. Call it deliberately in an appropriate server-side workflow; do not expose an unauthenticated catalog endpoint. For already-registered BullMQ instances, replace a definition with `{ queue: existingQueue, displayName: 'Mail' }`. The adapter reads only `queue.name` and `queue.opts.prefix`, never the connection, client, jobs, or other options. Any effects in your own queue-registry module are your application's responsibility.

The package uses `import 'server-only'` as recommended in [Next.js's server/client guidance](https://nextjs.org/docs/app/getting-started/server-and-client-components#preventing-environment-poisoning). A real Next.js build rejects importing it from a Client Component. Browser, Edge, and Pages Router support are not claimed. For a standalone Node CLI, use `@queuescope/node`; the Next.js package deliberately retains the real server-only guard outside Next.js.

## Optional explicit local file export

```ts
import { createQueueCatalog, writeQueueCatalogFile } from '@queuescope/next';

await writeQueueCatalogFile('/absolute/private/output/queue-catalog.json',
  createQueueCatalog([{ name: 'emails', prefix: 'my-app:bull' }]));
```

The parent directory must already exist. The writer validates the full catalog before touching disk, writes a mode-0600 temporary file in that directory, and atomically exposes the completed file without replacing existing files or destination symlinks. Existing paths fail with `EEXIST`. Select a fresh path for each export, or explicitly remove a previous export yourself. Keep exports outside `public/`, static hosting roots, source control, and shared directories. Queue names and labels may themselves be business-sensitive even though Redis credentials are never inspected.

Writable persistent storage is not guaranteed in serverless deployments. Prefer the pure API there and choose your own authorized artifact workflow. The file helper is intentionally opt-in and does not create directories or find an output path.

## Optional development-only instrumentation example

If you want a one-time local export when explicitly starting a development server:

```ts
// instrumentation.ts, beside app/ (or inside src/ beside src/app/)
export async function register() {
  if (process.env.NODE_ENV !== 'development' ||
      process.env.NEXT_RUNTIME !== 'nodejs' ||
      !process.env.QUEUESCOPE_EXPORT_PATH) return;

  const { createQueueCatalog, writeQueueCatalogFile } = await import('@queuescope/next');
  await writeQueueCatalogFile(process.env.QUEUESCOPE_EXPORT_PATH,
    createQueueCatalog([{ name: 'emails', prefix: 'my-app:bull' }]));
}
```

This is an example you must add and opt into; the package never installs a hook. Supply a fresh absolute `QUEUESCOPE_EXPORT_PATH`. A repeated server start using the same output path intentionally fails rather than overwriting it. The development guard keeps this example inactive during production builds and starts. The `NEXT_RUNTIME` guard and dynamic import follow [Next.js instrumentation guidance](https://nextjs.org/docs/app/guides/instrumentation); instrumentation can execute in more than one runtime/server instance.

The catalog only carries identities and optional display labels/groups. It does not create queues, load jobs, or change Redis ACL requirements. In QueueScope, connect to the intended existing connection, choose **Import queue catalog** in the sidebar, select the JSON file, and confirm the destination. Every prefix must match exactly. The file does not identify the Redis server: choosing the correct destination is essential.
