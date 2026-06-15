# QueueScope

Native macOS SwiftUI dashboard for inspecting and operating BullMQ queues.

QueueScope targets BullMQ `5.77.x` Redis layouts. It connects directly to Redis for dashboard reads, discovers BullMQ queues, shows queue health, pages jobs by state, opens job payloads/failures in an inspector, and routes job mutations through BullMQ's official Node package.

## Current Features

- Native SwiftUI three-pane macOS interface.
- Redis URL connection with `redis://` and `rediss://` parsing.
- Saved connection profiles in app preferences.
- BullMQ queue discovery via `SCAN` against `<prefix>:*:meta`.
- Queue counters for waiting, active, delayed, prioritized, completed, failed, paused, and waiting-children.
- Runs table by state with job id, name, attempts, duration, and payload preview.
- Job inspector for payload, options, progress, return value, failure reason, stack trace, and timestamps.
- Job actions for retrying completed/failed jobs, promoting delayed jobs, removing non-active jobs, and duplicating jobs with editable data/options.
- Local metric snapshots for queue trend charts without writing to Redis.
- Worker and scheduler key discovery panels.
- Sparkle-backed manual app update checks.

## Job Actions

QueueScope keeps direct Swift Redis access read-focused. Mutating job actions run through `BullMQActionBridge/bridge.mjs`, a small Node helper that uses the official `bullmq` package for `Job.retry`, `Job.remove`, `Job.promote`, and `Queue.add`.

The Xcode build packages the bridge and its locked production dependencies into `QueueScope.app`, so people using the built app do not run `npm install`. The build machine needs npm available so the `Package BullMQ action bridge` build phase can install the locked bridge dependencies into the app bundle. The app runs the packaged bridge with Node from `BULLMQ_NODE_PATH`, Homebrew, `/usr/local`, `/usr/bin`, or nvm; set `BULLMQ_ACTION_BRIDGE_PATH` only when deliberately overriding the packaged bridge during development.

## App Updates

QueueScope uses Sparkle 2 for direct-distribution app updates. The app checks the GitHub Releases appcast only when `Check for Updates...` is selected:

```text
https://github.com/raynirola/queuescope/releases/download/appcast/appcast.xml
```

The Sparkle public EdDSA key is embedded in the app. The private signing key stays on the release machine and is required when generating release appcasts.

Release flow:

1. Build a Release archive of `QueueScope.app`.
2. Sign and notarize the app.
3. Package the notarized app as a `.zip` or `.dmg`.
4. Run Sparkle's `generate_appcast` tool over the folder containing the packaged update archive.
5. Upload the update archive and generated `appcast.xml` to the GitHub release tag named `appcast`.

Until `appcast.xml` exists at the release URL, `Check for Updates...` may show Sparkle's standard feed-not-found error.

## Run

Open the Xcode project:

```sh
xed BullMQDashboard.xcodeproj
```

Select the `BullMQDashboard` scheme and press Run. The app builds as QueueScope.

## Test

```sh
xcodebuild -project BullMQDashboard.xcodeproj -scheme BullMQDashboard -configuration Debug build
```

## Architecture

- `App`: app entrypoint and shared state.
- `UI`: SwiftUI sidebar, dashboard, tables, charts, and inspector.
- `Domain`: BullMQ models, parsing, engine protocol, state enums.
- `BullMQRedisEngine`: pure Swift direct Redis read engine plus a narrow BullMQ mutation bridge client.
- `Persistence`: connection profiles, workspace preferences, queue metadata, and local metric snapshots.

The UI talks to `BullMQEngine`, keeping Redis reads and BullMQ-backed writes behind one replaceable interface.

## Safety

Dashboard refreshes use read-style Redis commands such as `SCAN`, `LLEN`, `ZCARD`, `LRANGE`, `ZREVRANGE`, and `HGETALL`. Job mutations are limited to the inspector actions and are delegated to BullMQ itself, so locked jobs, wrong-state retries, and invalid promotions fail with BullMQ errors instead of hand-edited Redis state.
