# Distribution

QueueScope ships as a signed, notarized universal macOS app through GitHub Releases and the [Homebrew tap](https://github.com/raynirola/homebrew-tap). The [public website](https://raynirola.github.io/queuescope/) is deployed from `site/` by `.github/workflows/pages.yml` on main.

## Release updates

1. Publish and verify the signed release ZIP and Sparkle feed.
2. Update the version and SHA-256 in `Casks/queuescope.rb` here and in the tap. Run `brew audit --cask raynirola/tap/queuescope`, `brew style --cask raynirola/tap/queuescope`, and `brew fetch --cask raynirola/tap/queuescope` against the updated cask.
3. Update website version labels, download URLs, compatibility details, and privacy version when behavior changes. Use sample-data screenshots only.
4. Verify the public Pages URL and download after deployment. Preview locally with `python3 -m http.server 8765 --directory site` from the repository root.

The tap is maintained separately; a change to the mirrored cask in this repository does not publish a tap update automatically.

See [App Store feasibility](../docs/APP_STORE_FEASIBILITY.md) for remaining Store-specific engineering.
