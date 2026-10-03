# Queue catalogs and adapters

QueueScope is an npm-workspaces monorepo alongside the native app:

- `packages/action-bridge`: private BullMQ mutation helper, independently locked at BullMQ 5.77.0
- `packages/node`: pure, explicitly registered queue-catalog serializer (`@queuescope/node`)
- `packages/next`: server-only Next.js App Router integration and optional explicit local file writer (`@queuescope/next`)

The Xcode project, native app, static site, distribution files, and release scripts stay at the repository root. The packaged app still loads `Contents/Resources/BullMQActionBridge`. Building the bridge copies its manifest and independent lock into an isolated system-temporary directory and runs `npm ci --omit=dev --omit=optional --ignore-scripts --workspaces=false`; it never copies workspace `node_modules` into the app.

## Why export a catalog?

An application can declare exactly which queues belong in a QueueScope workspace and supply useful display labels/groups. A catalog can also contain explicit definitions for queues your application has not instantiated yet; exporting or importing those definitions does not create or activate them.

This is an inventory and organization feature. BullMQ normally writes its queue metadata key during `Queue` initialization (unless configured with `skipMetasUpdate`), so empty queues are not universally invisible to Redis discovery. Catalogs do not change QueueScope's Redis reads or remove its normal `SCAN`/ACL requirements. The adapters never enumerate Redis, instantiate queues, call queue methods, export connection settings, or start a dashboard server.

## Install from this repository

These packages are not published to npm by this change. From a clone:

```sh
npm ci --ignore-scripts
npm test
npm run test:packages
mkdir -p /tmp/queuescope-packs
npm pack ./packages/node --pack-destination /tmp/queuescope-packs
npm pack ./packages/next --pack-destination /tmp/queuescope-packs
```

In a Node application, install the Node tarball. In a Next.js 16 App Router application, install both tarballs together:

```sh
# Node application:
npm install /tmp/queuescope-packs/queuescope-node-0.1.0.tgz
# Next.js application (both in the same command):
npm install /tmp/queuescope-packs/queuescope-node-0.1.0.tgz /tmp/queuescope-packs/queuescope-next-0.1.0.tgz
```

The Next adapter depends on the matching `@queuescope/node` version. Keep the tarball files available to the consuming application's lockfile workflow. The adapters require Node.js 22 or later. The Node package has no BullMQ runtime dependency; it accepts the structural identity fields of registered BullMQ Queue instances.

## Node.js: explicit, credential-free metadata

```js
import { writeFile } from 'node:fs/promises';
import { createQueueCatalog, serializeQueueCatalog } from '@queuescope/node';
import { emailQueue, reportQueue } from './existing-queue-registry.js';

const catalog = createQueueCatalog([
  { queue: emailQueue, displayName: 'Transactional email', group: 'Messaging' },
  { queue: reportQueue, group: 'Analytics' },
]);

// Only this explicit application call writes a file. Choose a private path.
await writeFile('/absolute/private/queue-catalog.json', serializeQueueCatalog(catalog),
  { flag: 'wx', mode: 0o600 });
```

For definitions without queue instances:

```js
const catalog = createQueueCatalog([
  { name: 'emails', prefix: 'my-app:bull', displayName: 'Mail', group: 'Messaging' },
]);
```

An instance registration reads only `queue.name` and `queue.opts.prefix`. A missing instance prefix uses BullMQ's `bull` default; explicit definitions require a prefix. The registration wrapper rejects unknown fields. Connection options, passwords, URLs, hosts, client getters, and queue methods are never read or copied. Your own registry may initialize connections when imported; the adapter does not make that application code side-effect-free. Do not place secrets in queue names, labels, or groups.

See [`@queuescope/next`](../packages/next/README.md) for server-only production usage, explicit file output, and a development-only opt-in instrumentation example. No public endpoint is supplied.

## Import into the native app

1. Select and connect to the intended existing Redis connection in QueueScope.
2. Choose **Import queue catalog** (the import icon in the sidebar).
3. Select the JSON file and review the named connection, endpoint, prefix, and queue count.
4. Confirm the import. The entire catalog must validate and every prefix must exactly match the captured connection.

Names and prefixes do not identify a Redis server. A catalog contains no host, database, URL, credentials, or connection identity, so it must never create a connection or automatically choose its destination. If you switch/reconnect while the file is open, the stale import is rejected. Import affects only locally saved queue metadata; it does not connect, select/refetch a queue, create Redis keys, or change read-only/action permissions. Existing queues, labels, and groups, including labels/groups you cleared, remain unchanged on repeated imports. New queues are added atomically and persist for that connection's workspace. Subsequent browsing uses the existing Redis read engine normally. Saved queue names, metadata, and workspace preferences migrate lazily to byte-exact scope keys, keeping canonically equivalent Unicode Redis prefixes separate. Profile credentials are unaffected; older app versions do not understand newly saved scope keys.

## Version 1 file format

```json
{
  "schema": "queuescope.queue-catalog",
  "version": 1,
  "queues": [
    { "name": "emails", "prefix": "my-app:bull", "displayName": "Mail", "group": "Messaging" }
  ]
}
```

The parser accepts plain UTF-8 JSON and rejects UTF-16/32, byte-order marks, unknown fields and versions, missing fields, wrong types, explicit null labels, duplicate `(prefix, name)` identities, control characters, leading/trailing Unicode whitespace, and colon-containing queue names. Prefixes may contain colons. Unicode identifiers are preserved exactly: no trimming, lowercasing, or normalization. Limits are 1 MiB UTF-8 JSON, 1,000 queues, 512 UTF-8 bytes per name/prefix, and 256 per optional displayName/group. Empty catalogs are valid no-ops. Mixed-prefix catalogs can be serialized but cannot be imported together into one connection; export one matching inventory per connection.

## Validation

```sh
npm ci --ignore-scripts
npm test
npm run test:packages
node --test tests/packaging/bridge.test.mjs
npm run test:bridge # requires a local redis-server; uses isolated loopback Redis
python3 -B -m unittest discover -s tests/release -v
```

Package tests install real tarballs outside the workspace, check TypeScript against real BullMQ Queue types, build a production Next.js Server Component, and verify Client Component imports fail through the real server-only package. Shared fixtures under `tests/catalog` exercise the Node serializer and native XCTest parser. The macOS CI job builds/tests the SwiftUI importer, including all-or-nothing rejection, destination races, idempotency, label preservation, persistence, and no Redis/permission mutations.
