# Start with QueueScope

QueueScope is a native macOS app for BullMQ 5.77.x. It reads Redis directly; job mutations use the bundled official BullMQ package and Node runtime. No dashboard server, account, or separate Node installation is required to use a packaged build.

## Try the offline demo

Open Connection Manager and choose **Explore offline demo**. The demo contains three sample queues and three failure groups. Expand an error group, inspect a job, and open its parent/child flow. Demo data stays offline and all mutations are disabled.

To leave the demo, open Connection Manager, disconnect, and connect to your Redis instance. The demo does not replace your saved connection settings.

## Connect to Redis

1. Enter a name, Redis URL, and BullMQ prefix (usually `bull`). Use `redis://` for TCP or `rediss://` for TLS. Percent-encode reserved characters in credentials.
2. Enable **Read-only connection** when you only need inspection.
3. Choose **Test connection** to check network/TLS, Redis authentication, and queue discovery permission without changing the current session.
4. Choose **Connect**. A new workspace discovers queues automatically; use **Discover queues** and **Scan more** if more Redis keys remain. You can also add a queue by name.
5. Choose **Save** to remember the connection. Release builds store Redis credentials in Keychain.

Redis ACLs must allow the reads used by the app, including `PING`, `SCAN`, list/sorted-set reads, and hash reads. Worker discovery also requires `CLIENT LIST`. An app read-only profile prevents QueueScope mutations; Redis ACLs provide server-side enforcement.

## Connect through SSH

Enable **Connect through SSH** and enter the SSH host (or a `~/.ssh/config` alias), username, port, and optional private-key path. The port field is explicit; enter the port configured for your alias if it differs from 22.

QueueScope uses macOS OpenSSH, your SSH agent or key, and your existing known-hosts file. Verify a new host with `ssh` in Terminal first. For a passphrase-protected key, load it into your agent with `ssh-add` before connecting. Interactive SSH password prompts are not supported.

The Redis URL names the destination as seen by the SSH server. For example, use `redis://127.0.0.1:6379` when Redis runs on the SSH server itself. For TLS, use the Redis certificate's hostname: certificate verification keeps that hostname even though traffic travels through a local forward.

Forwards listen only on loopback. Disconnecting, switching connections, or quitting the app closes the tunnel. QueueScope never adds or overrides trusted SSH host keys.

## Investigate a failure

1. Open **Failure inbox**. It scans retained failed jobs for the selected queue and refreshes when you select a different queue. Enable **All queues** to group failures across discovered and saved queues in the active connection/prefix. Switching scope resets scan pagination and the previous-scan comparison.
2. Use **Scan more** to continue a partial scan. Each action reads at most five pages of 100 entries; the coverage indicator identifies partial results.
3. Filter by error text or queue name, then expand a group. UUIDs and long hexadecimal identifiers are normalized in the first error line; HTTP/error codes remain distinct.
4. Review affected queues, failure timestamps, and a representative payload. Choose **Inspect** for a full error, payload, attempts, and available actions. Existing job confirmations and read-only restrictions still apply.
5. Scan again after fixing the cause. Newly observed jobs are compared with the previous completed scan in this session. This indicates new observations, not a guaranteed arrival rate.

The inbox is a view of retained jobs, not a historical incident database. Deleted jobs cannot be reconstructed. A live queue can change during pagination; a scan is not a transactional snapshot. Discovery may be incomplete until you scan all Redis keys.

## Development credentials

Debug builds use a separate local, unencrypted credential store to avoid Keychain authorization prompts after rebuilds. Save each development connection once. Debug builds do not read or migrate release Keychain entries, and deleting a development profile leaves release profiles intact. Use release builds for Keychain-backed storage.

## Build and packaging

The build still needs Node/npm for installing locked bridge dependencies. Packaging downloads official Node 22.23.3 binaries with pinned SHA-256 verification, embeds the architectures requested by Xcode, includes Node's license, and signs the nested runtime before app signing. The first build needs network access; verified archives are cached under DerivedData. Update both pinned digests when upgrading Node.

Before publishing, build the intended architectures, run the tests, inspect light/dark UI captures, and complete normal app signing/notarization. A successful local build is not a published release.
