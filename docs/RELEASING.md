# Releasing QueueScope

The `Release` workflow builds and verifies the signed app on GitHub's ephemeral macOS runner. Releases do not need a Mac to remain online after the one-time credential setup. The existing Sparkle public key and feed URL are preserved.

## One-time setup (repository owner)

These steps grant GitHub Actions persistent ability to sign and distribute QueueScope. Review the workflow before adding credentials. Enter private values directly into GitHub, never in chat, issues, source files, or this document.

1. Ensure the GitHub connection used to submit this change has write access to `raynirola/queuescope`, including permission to change workflows. A read-only connection cannot open the implementation PR. This is separate from release signing credentials.
2. In the QueueScope repository, open **Settings → Environments**, create `release`, restrict deployment branches to **Selected branches and tags → main** (branch only), and add Ray as a required reviewer. Require review of each release run. Do not allow untrusted PR branches to use the environment. Do not disable existing branch protections.
3. Add these **environment secrets** to `release`:

| Secret | Value entered securely by the owner |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 of the existing **Developer ID Application** certificate and its private key exported together as an encrypted `.p12` from the release Mac. Use the identity for team `TH48DG8RVN`, not an Apple Development or Installer certificate. |
| `DEVELOPER_ID_P12_PASSWORD` | Password chosen when exporting that `.p12`. |
| `APPLE_ID` | Apple ID already authorized to notarize for that team. |
| `APPLE_APP_SPECIFIC_PASSWORD` | An app-specific password created by the owner at [Apple Account](https://account.apple.com/) for this notarization use. This is not the Apple ID's ordinary password. |
| `SPARKLE_ED_PRIVATE_KEY` | Export of the **existing** Sparkle signing key corresponding to the public key already embedded in QueueScope. Do not generate a replacement key. |
| `HOMEBREW_TAP_TOKEN` | An owner-created fine-grained GitHub token with access to **only `raynirola/homebrew-tap`** and **Contents: read and write**. Choose an expiry and rotate it when needed. No admin, Actions, workflow, organization, or unrelated repository permissions are required. |

Only the first five secrets are required for a signed test build. The tap token is required before a run can publish all distribution channels. The built-in `GITHUB_TOKEN` handles the QueueScope release, source metadata and Pages dispatch; no QueueScope personal token is needed by the workflow.

### Secure copy from the existing release Mac

The owner performs these operations themselves. No assistant or CI task needs to read the Mac's keychain or copy secrets through chat.

- In Keychain Access, select the existing Developer ID Application certificate **with its private key**, export as `.p12`, and choose a strong temporary export password. Keep the export private. On that Mac, `base64 -i /path/to/QueueScope-Developer-ID.p12 | pbcopy` copies its base64 directly to the clipboard for GitHub's secret field. Paste the export password into its separate field.
- Use the `generate_keys` tool from the project's pinned Sparkle 2.9.3 SDK to export the existing key: `generate_keys -x /private/local/path/queuescope-sparkle-key`. Copy that file's single secret value directly into `SPARKLE_ED_PRIVATE_KEY`. Do not run a key-generation command. The pipeline verifies signatures against the existing embedded public key and rejects a mismatched export.
- Apple ID/app-specific password and the narrowly scoped tap token go directly into their named GitHub fields. Delete temporary export files when the secrets are saved, retain the normal secure backups, and clear the clipboard. Never commit exports or paste their values into a terminal command that saves shell history.

The public key expected by existing apps is `wm5B2dbY1t3GYcdr3oB1z2omXQsBtn8d1nVu4GVc8c0=`. It is public information and is not the value to place in the private-key secret.

## First release: 0.5.1 / build 8

The release packaging also excludes optional architecture-specific Node accelerators and uses their pure-JS fallback, avoiding unsigned native add-ons in the universal app. The source changes after 0.5.0 include the failure-inbox queue-switch fix in PR #16. Later commits change the website/distribution material, not app functionality. This patch advances all app/test version settings to 0.5.1/build 8.

1. Review and merge the implementation/version-bump PR after normal checks pass. Do not update live download links early.
2. On **Actions → Release → Run workflow**, choose `main`, version `0.5.1`, and the exact full commit SHA now on main. Leave `publish` false for the initial signed test run. The workflow refuses an input SHA that differs from its checkout, invalid versions, mismatched Xcode metadata, a changed Sparkle public key, or a non-main/fork invocation.
3. Approve the protected `release` environment after checking the source commit. A successful run yields an artifact containing a Developer ID-signed, Apple-notarized, stapled universal ZIP, a signed Sparkle enclosure, checksums and source manifest. Download and smoke-test it on a Mac: selected queue → another queue → empty queue → All queues → selected queue; also test switching during an in-flight scan. Existing GitHub macOS CI exercises the regression tests, but this initial workflow has not yet been exercised with production credentials.
4. Run the same source commit with `publish` true and approve the release. The app is rebuilt and reverified. Publication is allowed only after all checks pass. If main changed meanwhile, use the current reviewed main commit or re-review; do not mislabel a new source commit as the old one.

Later releases follow the same path after bumping `MARKETING_VERSION`, incrementing `CURRENT_PROJECT_VERSION`, and adding `docs/releases/<version>.md`.

## Publication order and safeguards

1. Test Swift and BullMQ regressions without secrets.
2. Archive and export a universal Developer ID app. Verify both app and Node architectures, Developer ID authority/team, hardened runtime and secure timestamps. Apple notarization must return `Accepted`; staple and validate the ticket, then verify Gatekeeper acceptance.
3. Create the final ZIP **after stapling**. Preserve existing Sparkle feed history and verify the new Ed25519 archive signature with the public key embedded in the app. No ad-hoc or unsigned build is publishable.
4. Publish `v<version>` from the exact tested source commit. Existing version assets must match byte-for-byte; they are never silently overwritten. Upload the identical ZIP to the stable `appcast` release. Download both public ZIP URLs and compare SHA-256 before replacing the live feed. A failed feed upload attempts restoration of the previous feed.
5. Validate the new Homebrew cask with style, audit and fetch checks, then update the separate tap. Update the mirrored cask and every website version/download reference, preserving concurrent work. Dispatch the existing Pages workflow explicitly because a `GITHUB_TOKEN` commit does not itself trigger another push workflow. Require the exact deployment to succeed and verify the public homepage.

Homebrew online checks run in a separate contents-read-only job with an ephemeral GitHub token, avoiding shared-runner anonymous API rate limits. The write-enabled publisher accepts only the exact cask content digest returned by that validation job; if the live tap changed, it stops and requires fresh validation. GitHub write tokens are never passed to Homebrew.

The workflow is serialized and must be the exclusive writer of the live appcast. GitHub release assets have no atomic compare-and-swap operation; observed outside changes stop publication. Avoid manual feed edits during a run. A copy of the previous feed is retained in the run artifact for recovery. Signing material is stored only in temporary protected files/keychain, removed by a shell trap and an `always()` cleanup step, and never included in artifacts or caches. Actions are pinned to commit SHAs. Pull requests do not run the release workflow or receive its environment secrets.

## Failure and recovery

- Failed tests/signing/notarization/Sparkle verification stop before publication. Diagnose the error; never weaken the checks or replace the private key just to make a run pass.
- Drafts are resolved from the authenticated release list, then checked by numeric ID; the published-only tag endpoint is not used for draft lookup. A draft with the wrong source commit fails before uploads. If fixing release tooling changes main after an empty draft was created, explicitly review that draft’s ID, old target, unpublished state, empty assets and absent Git tag before updating its target to the new reviewed commit. Preserve the intended `tag_name` explicitly in the same REST PATCH, or use `gh release edit --target`, which preserves it; GitHub removes the pending tag when a raw PATCH omits `tag_name`. Recheck immediately before the update, read back afterward, and build fresh artifacts; never retarget a populated or published release.
- Retry a failed job from the same run for transient upload/distribution errors. Matching release assets are reused and mismatched assets stop the run. If the live appcast has independently changed, rebuild from the current feed instead of overwriting it.
- A GitHub release and Sparkle update can succeed before a tap or Pages failure. The workflow then fails visibly; use its failed job and exact public checks to finish those channels. Do not report the whole release as complete until all jobs are green.
- Branch-protection or token permission failures are blockers, not reasons to force-push or bypass rules. Apply the prepared metadata change through the repository's review process or explicitly authorize a supported automation identity under the existing rules.
- The tap token cannot change QueueScope, and the built-in token cannot change the tap. An expired/missing token fails the publish preflight. Certificate expiry/revocation or expired Apple credentials require owner updates in the protected environment.

## Verification in a development checkout

```sh
python3 -B -m unittest discover -s tests/release -v
for script in scripts/release/*.sh; do bash -n "$script"; done
actionlint .github/workflows/release.yml .github/workflows/tests.yml
git diff --check
```

These validate helpers and workflow structure. They do not establish Apple signing, notarization, Sparkle private-key availability, Homebrew acceptance, or public delivery; those are verified by the actual macOS workflow.

## References

- [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub Xcode signing](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub environment secrets](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
- [GitHub token and workflow triggers](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [Sparkle distribution and signing](https://sparkle-project.org/documentation/)
