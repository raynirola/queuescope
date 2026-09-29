# Mac App Store feasibility

Assessed September 29, 2026 against QueueScope 0.5.0. Keep direct download and Homebrew distribution while preparing a separate App Store build. No App Store submission has been made.

## Finding

The bundled Node runtime and BullMQ operations can run inside an inherited App Sandbox. The current SSH configuration flow cannot be carried over unchanged: sandboxed OpenSSH cannot freely read configuration and keys outside the app container. A dedicated Store configuration and an explicit credential-import design are needed before submission.

## Runtime evidence

A local, ad-hoc-signed Swift `.app` probe used the released universal Node 22.23.3 binary and bundled BullMQ 5.77.0 dependencies on Apple Silicon. The parent had `com.apple.security.app-sandbox`, `network.client`, and `network.server`; Node had `app-sandbox`, `inherit`, and `cs.allow-jit`. Tests used a disposable Redis instance bound to loopback, with no production credentials or data.

| Probe | Observed result |
| --- | --- |
| Parent home directory | Redirected to the probe's sandbox container |
| Bundled Node process | Started successfully, reported v22.23.3 |
| Read a generated file outside the container | Denied with `EPERM`, confirming confinement |
| Node TCP connection to local Redis | `+PONG` |
| Bundled BullMQ add, fetch, remove, and fixture queue cleanup | Completed successfully; fetched payload matched |
| System OpenSSH reading an explicit generated external config file | Exit 255: `Operation not permitted` |

The SSH failure occurs before authentication. It establishes a real filesystem blocker; it does **not** prove that sandbox-compatible SSH is impossible. System-agent sockets, key selection, known-host persistence, local forwarding, Redis TLS over a tunnel, and complete app behavior still need end-to-end validation. Intel execution and Store signing were not tested by this probe. The probe is an engineering feasibility result, not an App Review approval guarantee.

## Work required before submission

1. Add a separate Store build configuration with App Sandbox, outgoing network access, and incoming access for local tunnel listeners. Preserve the existing direct-distribution configuration.
2. Sign embedded Node with sandbox inheritance and JIT entitlements; sign every native addon. Validate the entire packaged bridge under Store signing on Apple Silicon and Intel.
3. Replace implicit access to `~/.ssh` with a user-approved import or selection flow. Prefer container-owned copies for helper-readable configuration and known-host state; account for encrypted keys, passphrases, revocation, and credential cleanup. Parent security-scoped file access does not automatically grant an inherited helper access to the same file.
4. Choose and validate a supported SSH authentication path. Do not promise arbitrary system-agent compatibility until socket access has been demonstrated. Preserve strict host verification and Redis TLS hostname checks.
5. Exclude Sparkle and its update UI/frameworks from the Store product; Store updates must use Apple's distribution mechanism.
6. Validate container migration of saved profiles and metric history, Keychain access, file import/export, offline demo, and every Redis mutation using only disposable fixtures.
7. Prepare Store screenshots, support and privacy URLs, privacy disclosures, export-compliance answers, and review instructions with the offline demo. Confirm licensing/attribution for bundled Node and npm dependencies.

## Decision gate

Proceed to Store packaging after SSH key/known-host handling, the full Node bridge, container migration, and Store signing pass. Then evaluate submission separately. Direct distribution is already usable and should remain available during this work.

## Primary references

- [Apple: protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple: embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- [Apple: sandbox entitlement inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)
- [App Review Guidelines, particularly 2.4.5 and 2.5.2](https://developer.apple.com/app-store/review/guidelines/)
