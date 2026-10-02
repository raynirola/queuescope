# Website download metrics

The QueueScope website stream for `https://queuescope.app` uses measurement ID `G-MSGLSK2RV2`, managed under `raynirola@gmail.com`. The Google tag loads only after visitors allow analytics; the choice is stored locally and can be changed with Analytics settings. Advertising personalization and Google signals are disabled. Deployment uses the existing GitHub Pages workflow.

The website records the following events. `download_click` and `homebrew_copy` are registered as GA4 key events, counted once per event with no assigned monetary value.

| Event            | Meaning                                                                  | Parameters                                                         |
| ---------------- | ------------------------------------------------------------------------ | ------------------------------------------------------------------ |
| `page_view`      | Page visit, collected by the Google tag on the landing and privacy pages | GA4 standard parameters                                            |
| `download_click` | A ZIP download button was clicked                                        | `download_location` (`hero` or `install`), `link_url`, `file_name` |
| `homebrew_copy`  | The install command was successfully copied                              | `install_method` (`homebrew`)                                      |

GA4 has an event-scoped custom dimension, Download location (`download_location`), to compare the buttons in reports. Account ID: `410487747`; property ID: `557114183`; stream ID: `15941977189`. Use Realtime to verify the events after deployment, then Reports or Explorations for trends. Visitors who decline analytics are not counted. Analytics blockers can also prevent collection; downloads continue normally when tracking is blocked.

Enhanced measurement can also emit `file_download` for ZIP links. Keep that separate from `download_click`; adding the two event counts would double-count clicks. Neither click events nor command copies confirm completed downloads or installations. GitHub release asset `download_count` supplies a separate download count, including traffic that does not pass through the website.

Before considering setup complete, verify the deployed page loads the correct Google tag and click each download button and copy the Homebrew command. Confirm `download_click` and `homebrew_copy` arrive in the intended property's Realtime view. The privacy page describes website analytics; the desktop app does not include Google Analytics.

References: [Google tag page views](https://developers.google.com/analytics/devguides/collection/ga4/views), [GA4 enhanced measurement](https://support.google.com/analytics/answer/9216061).
