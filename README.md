# BullMQ Dashboard

Native macOS SwiftUI dashboard for BullMQ queues.

The first implementation is a read-only desktop app targeting BullMQ `5.77.x` Redis layouts. It connects directly to Redis, discovers BullMQ queues, shows queue health, pages jobs by state, and opens job payloads/failures in an inspector.

## Current Features

- Native SwiftUI three-pane macOS interface.
- Redis URL connection with `redis://` and `rediss://` parsing.
- Saved connection profiles with secrets stored in macOS Keychain.
- BullMQ queue discovery via `SCAN` against `<prefix>:*:meta`.
- Read-only queue counters for waiting, active, delayed, prioritized, completed, failed, paused, and waiting-children.
- Runs table by state with job id, name, attempts, duration, and payload preview.
- Job inspector for payload, options, progress, return value, failure reason, stack trace, and timestamps.
- Local metric snapshots for queue trend charts without writing to Redis.
- Worker and scheduler key discovery panels.

## Run

Open the Xcode project:

```sh
xed BullMQDashboard.xcodeproj
```

Select the `BullMQDashboard` scheme and press Run.

## Test

xcodebuild -project BullMQDashboard.xcodeproj -scheme BullMQDashboard -configuration Debug build
```

## Architecture

- `App`: app entrypoint and shared state.
- `UI`: SwiftUI sidebar, dashboard, tables, charts, and inspector.
- `Domain`: BullMQ models, parsing, engine protocol, state enums.
- `BullMQRedisEngine`: pure Swift direct Redis read engine.
- `Persistence`: connection profiles, Keychain credentials, local metric snapshots.

The UI talks to `BullMQEngine`, keeping the direct Redis implementation replaceable if a future BullMQ sidecar becomes necessary.

## Safety

This version does not issue BullMQ write commands. Redis access is limited to read-style commands such as `SCAN`, `LLEN`, `ZCARD`, `LRANGE`, `ZREVRANGE`, and `HGETALL`.
