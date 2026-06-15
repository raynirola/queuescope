import SwiftUI

struct JobDraftSheet: View {
    let title: String
    let message: String
    let submitTitle: String
    @Binding var draft: JobDuplicateDraft
    let isSubmitting: Bool
    let submit: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Job name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                JobJSONEditor(title: "Data", text: $draft.dataJSON)
                    .frame(minHeight: 190)

                JobJSONEditor(title: "Options", text: $draft.optionsJSON)
                    .frame(minHeight: 190)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)

            Spacer(minLength: 0)
            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(submitTitle)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil || isSubmitting)
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var validationMessage: String? {
        if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Name is required."
        }
        do {
            _ = try AppModel.parseDuplicateJSON(draft.dataJSON, label: "Data")
            _ = try AppModel.parseDuplicateJSON(draft.optionsJSON, label: "Options")
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct JobJSONEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08))
                }
        }
    }
}
