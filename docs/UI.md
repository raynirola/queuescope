# QueueScope UI conventions

Use native SwiftUI controls and semantic macOS colors so light/dark appearances and keyboard behavior stay aligned with the system.

- Use 24-point workspace margins, 16-point card/form padding, and 8–12-point spacing between related controls.
- Use `dashboardSurface()` for neutral cards and grouped details: a semantic background, 10-point corners, and a subtle border. Keep state colors for health and job status.
- Workspace titles use the existing 28-point heading; section titles use semibold subheadlines; field labels and secondary details use captions.
- Keep action buttons outside scrolling forms. Separate pagination from mutation controls. Use prominent buttons for form submission and native confirmation alerts for destructive actions.
- Size content to its pane, not the whole window. Wrap status badges and grids; allow long detail text to truncate or wrap intentionally. Keep full values selectable in detail views.
- Keep sidebar search docked below its list. Selected rows need readable labels, badges, and action icons in both appearances.
- Use the same minimum window size at the app and root view. The inspector must have a visible close control.

## Visual verification

`AppModelRefreshTests.testCompleteWindowLayoutsRender` renders all seven workspace views at 1120 and 1400 points in light and dark mode, using isolated fake data. It also renders connection management, job editing, the inspector, and queue/group forms. PNGs are written to `/tmp/queuescope-layout-*.png` and retained as XCTest attachments.

Inspect the rendered images after layout changes. Successful rendering alone does not prove that content fits or has adequate contrast. Test data must include populated and long-content cases; never use saved production connections for UI fixtures.
