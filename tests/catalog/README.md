# Queue catalog cross-language fixtures

Node and Swift use these same JSON files to pin the version-1 wire contract.

| Fixture | Expected result |
| --- | --- |
| `valid-v1.json` | Four entries, all prefix `team:prod`. Unicode labels and queue names, including both NFC `café` and NFD `café` as distinct identities. |
| `empty-v1.json` | Valid empty catalog. |
| `mixed-prefix-v1.json` | Valid export with two entries; native import into either single-prefix connection must fail atomically. |
| `malformed.json` | Invalid JSON. |
| `duplicate-v1.json` | Invalid duplicate name/prefix pair. |
| `unknown-fields-v1.json` | Invalid nested connection field; fixture credential is deliberately synthetic. |
| `unsupported-version.json` | Unsupported version. |
| `invalid-name-v1.json` | Invalid colon in a queue name. |
| `invalid-whitespace-v1.json` | Invalid leading whitespace in a label. |
| `invalid-control-v1.json` | Invalid U+0085 C1 control character inside a group. |

Strings are not trimmed or Unicode-normalized. Identifiers are at most 512 UTF-8 bytes; labels at most 256 bytes. Reject Unicode White_Space or U+FEFF at either edge, C0/C1 controls anywhere, and malformed Unicode. Prefixes may contain colons. Valid catalogs have at most 1,000 queues and 1 MiB serialized UTF-8 JSON; size/count boundary cases are generated in tests rather than stored as large fixtures.
