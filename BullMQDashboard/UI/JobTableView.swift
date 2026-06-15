import SwiftUI

struct JobTableView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isBulkRemoveConfirmationPresented = false
    @State private var isAddJobSheetPresented = false
    @State private var addJobDraft = JobDuplicateDraft(name: "", dataJSON: "{}", optionsJSON: "{}")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Runs", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                LoadingSpinnerSlot(isVisible: model.activeLoadingPhases.contains(.runs))
                if model.selectedVisibleJobCount > 0 {
                    Text("\(model.selectedVisibleJobCount) selected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Button {
                    addJobDraft = JobDuplicateDraft(name: "", dataJSON: "{}", optionsJSON: "{}")
                    isAddJobSheetPresented = true
                } label: {
                    Label("Add job", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(model.selectedQueue == nil || model.activeJobAction != nil)

                Menu {
                    Button {
                        model.retrySelectedJobs()
                    } label: {
                        Label("Retry eligible", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(model.selectedBulkRetryCount == 0)

                    Button {
                        model.promoteSelectedJobs()
                    } label: {
                        Label("Promote delayed", systemImage: "arrow.up")
                    }
                    .disabled(model.selectedBulkPromoteCount == 0)

                    Divider()

                    Button(role: .destructive) {
                        isBulkRemoveConfirmationPresented = true
                    } label: {
                        Label("Remove eligible", systemImage: "trash")
                    }
                    .disabled(model.selectedBulkRemoveCount == 0)
                } label: {
                    Label("Bulk actions", systemImage: "checklist")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .disabled(model.selectedVisibleJobCount == 0 || model.activeJobAction != nil)
                Text(model.runPageRangeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Button {
                        model.goToPreviousRunPage()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canGoToPreviousRunPage)

                    Button {
                        model.goToNextRunPage()
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!model.canGoToNextRunPage)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .frame(height: 28)
            .alert("Remove selected jobs?", isPresented: $isBulkRemoveConfirmationPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    model.removeSelectedJobs(removeChildren: true)
                }
            } message: {
                Text("This removes \(model.selectedBulkRemoveCount) non-active selected jobs and their children from BullMQ. Active or locked jobs may be rejected by BullMQ.")
            }
            .sheet(isPresented: $isAddJobSheetPresented) {
                JobDraftSheet(
                    title: "Add job",
                    message: "Add a new job to \(model.selectedQueue?.resolvedDisplayName ?? "this queue").",
                    submitTitle: "Add",
                    draft: $addJobDraft,
                    isSubmitting: model.activeJobAction == .add,
                    submit: {
                        guard let queue = model.selectedQueue else { return }
                        model.addJob(to: queue.name, draft: addJobDraft)
                        isAddJobSheetPresented = false
                    },
                    cancel: {
                        isAddJobSheetPresented = false
                    }
                )
                .frame(width: 680, height: 620)
            }

            if model.jobs.isEmpty {
                RunsEmptyState(state: model.selectedState)
            } else {
                VStack(spacing: 8) {
                    RunsHeader(
                        allVisibleSelected: model.allVisibleJobsSelected,
                        toggleSelection: {
                            model.toggleAllVisibleJobSelection()
                        }
                    )
                    ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                        RunsRow(
                            job: job,
                            isSelected: model.selectedJob?.id == job.id,
                            isChecked: model.isJobSelectedForBulk(job),
                            isAlternate: index.isMultiple(of: 2),
                            stateColor: stateColor(job.state),
                            attempts: attemptText(job),
                            duration: durationText(job.duration),
                            age: ageText(job),
                            toggleSelection: {
                                model.toggleJobSelection(job)
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectJob(job)
                        }
                    }
                }
            }
        }
    }

    private func attemptText(_ job: JobSummary) -> String {
        if let attempts = job.attempts {
            return "\(job.attemptsMade)/\(attempts)"
        }
        return "\(job.attemptsMade)"
    }

    private func durationText(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        return duration.compactDurationDisplay
    }

    private func ageText(_ job: JobSummary) -> String {
        if job.state == .delayed, let delayedUntil = job.delayedUntil, delayedUntil > Date() {
            return "in \(relativeDuration(from: Date(), to: delayedUntil))"
        }
        guard let date = job.finishedOn ?? job.processedOn ?? job.timestamp else { return "—" }
        let age = relativeDuration(from: date, to: Date())
        return age == "now" ? age : "\(age) ago"
    }

    private func relativeDuration(from start: Date, to end: Date) -> String {
        let interval = max(0, abs(end.timeIntervalSince(start)))
        if interval < 5 { return "now" }
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        if interval < 2_592_000 { return "\(Int(interval / 86_400))d" }
        if interval < 31_536_000 { return "\(Int(interval / 2_592_000))mo" }
        return "\(Int(interval / 31_536_000))y"
    }

    private func stateColor(_ state: BullMQState) -> Color {
        switch state {
        case .waiting: .teal
        case .active: .blue
        case .delayed, .waitingChildren: .orange
        case .prioritized: .purple
        case .completed: .green
        case .failed: .red
        case .paused: .gray
        }
    }
}

private struct LoadingSpinnerSlot: View {
    let isVisible: Bool

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .opacity(isVisible ? 1 : 0)
            .accessibilityHidden(!isVisible)
            .help(isVisible ? "Refreshing runs" : "")
    }
}

private struct RunsRow: View {
    let job: JobSummary
    let isSelected: Bool
    let isChecked: Bool
    let isAlternate: Bool
    let stateColor: Color
    let attempts: String
    let duration: String
    let age: String
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SelectionButton(isSelected: isChecked, action: toggleSelection)

            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconFill)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : stateColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(job.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    RunStatusText(
                        state: job.state,
                        color: stateColor,
                        isSelected: isSelected
                    )
                }
                Text("#\(job.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(rowSecondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

            RunMetric(title: "Duration", value: duration, isSelected: isSelected)
            RunMetric(title: "Attempts", value: attempts, isSelected: isSelected)
            RunMetric(title: "Age", value: age, isSelected: isSelected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(borderColor)
        }
    }

    private var background: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.82)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if isAlternate {
            return AnyShapeStyle(Color.primary.opacity(0.025))
        }
        return AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.86))
    }

    private var borderColor: Color {
        isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06)
    }

    private var iconFill: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.white.opacity(0.18))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [stateColor.opacity(0.20), stateColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var rowSecondary: Color {
        isSelected ? .white.opacity(0.78) : .secondary
    }

    private var icon: String {
        switch job.state {
        case .waiting: "clock"
        case .active: "bolt.fill"
        case .delayed: "calendar.badge.clock"
        case .prioritized: "arrow.up.forward"
        case .completed: "checkmark"
        case .failed: "xmark"
        case .paused: "pause.fill"
        case .waitingChildren: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct RunsHeader: View {
    let allVisibleSelected: Bool
    let toggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SelectionButton(isSelected: allVisibleSelected, action: toggleSelection)
            Text("")
                .frame(width: 30)
            Text("Job")
                .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            headerText("Duration")
            headerText("Attempts")
            headerText("Age")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .frame(width: 82, alignment: .trailing)
    }
}

private struct SelectionButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .help(isSelected ? "Deselect run" : "Select run")
    }
}

private struct RunMetric: View {
    let title: String
    let value: String
    let isSelected: Bool

    var body: some View {
        Text(value)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(isSelected ? .white.opacity(0.9) : .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        .frame(width: 82, alignment: .trailing)
    }
}

private struct RunStatusText: View {
    let state: BullMQState
    let color: Color
    let isSelected: Bool

    var body: some View {
        Text(state.displayName.lowercased())
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .tracking(0)
            .foregroundStyle(isSelected ? .white.opacity(0.72) : color.opacity(0.88))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct RunsEmptyState: View {
    let state: BullMQState?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private var title: String {
        guard let state else { return "No runs" }
        return "No \(state.displayName.lowercased()) runs"
    }

    private var message: String {
        guard state != nil else { return "This queue has no jobs in any visible state." }
        return "This queue has no jobs in the selected state."
    }
}
