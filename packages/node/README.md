# @queuescope/node

Build a credential-free QueueScope queue catalog from queues your application explicitly registers. This package has no runtime dependencies and does not connect to Redis.

```js
import { writeFile } from 'node:fs/promises';
import { createQueueCatalog, serializeQueueCatalog } from '@queuescope/node';

// `emailQueue` is an existing BullMQ Queue owned by your application.
const catalog = createQueueCatalog([
  { queue: emailQueue, displayName: 'Email', group: 'Messaging' },
  { name: 'reports', prefix: 'production:jobs', group: 'Back office' },
]);
await writeFile('queuescope-catalog.json', serializeQueueCatalog(catalog));
```

The result is a frozen snapshot with this shape:

```json
{"schema":"queuescope.queue-catalog","version":1,"queues":[{"name":"reports","prefix":"production:jobs","group":"Back office"}]}
```

Import it into QueueScope while explicitly selecting an existing connection. The catalog contains no connection information; import does not create a connection. Every prefix must exactly match the selected connection's prefix. A mixed-prefix catalog can be exported, but must be split before importing into separate connections.

## Safety boundary

Queue instance registrations read only `queue.name` and `queue.opts.prefix`. An undefined prefix uses BullMQ's default `bull`. The adapter never enumerates or spreads queue options, accesses a connection/client, calls queue methods, creates Queue instances, or reads/writes Redis. Explicit definitions can describe queues before your application instantiates them. This is an explicit list, not Redis discovery, and it does not prove a queue exists or is reachable. BullMQ itself may create metadata when your application constructs a Queue, even before it has jobs.

Only `name`, `prefix`, `displayName`, and `group` can be serialized for an entry. Unknown fields are rejected rather than silently dropped. Keep credentials and other private information out of these identity and label fields too. Validation errors do not echo supplied values. The catalog itself can reveal internal queue names and prefixes; protect any download endpoint with authentication and authorization.

## Validation

- At most 1,000 queues and 1 MiB of serialized UTF-8 JSON
- Required nonempty `name` and `prefix`, each at most 512 UTF-8 bytes
- Optional nonempty `displayName` and `group`, each at most 256 UTF-8 bytes
- No leading/trailing Unicode whitespace, C0/C1 controls, or malformed Unicode
- Queue names cannot contain `:`; prefixes can
- Exact duplicate `(prefix, name)` pairs are rejected; registration order is preserved
- No trimming, Unicode normalization, or deduplication is performed
- Only schema `queuescope.queue-catalog`, version `1`, and the documented fields are accepted

Both functions throw `QueueCatalogError` (`code: "ERR_QUEUE_CATALOG"`) for invalid input. `serializeQueueCatalog` validates again, so it is safe to use on parsed JSON after checking it at your application boundary. Plain objects, null-prototype objects, and dense arrays of data properties are supported; accessor fields and custom array properties are rejected. ESM and TypeScript declarations are included. Node.js 22 or newer is required.
