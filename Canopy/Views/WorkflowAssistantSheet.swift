import SwiftUI

/// Describe a workflow in plain language; the on-device model drafts it and
/// the result opens in the normal workflow editor for review before saving.
struct WorkflowAssistantSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onDraft: (Workflow) -> Void

    @State private var request = ""
    @State private var isWorking = false
    @State private var errorMessage: String? = nil
    @State private var result: WorkflowDraftResult? = nil
    @FocusState private var focused: Bool

    private let unavailableReason = WorkflowAssistant.unavailableReason

    private let examples = [
        "Offload new clips, make proxies, and email me when it's done",
        "Every night at 2am offload with verification, then delete files older than 30 days",
        "Offload, rename files with the shoot name, and transcribe them",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Describe a Workflow", systemImage: "sparkles")
                    .font(.canopyTitle2).foregroundStyle(Color.canopyInk)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Rectangle().fill(Color.canopyRule).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let unavailableReason {
                        Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Color.canopyRust)
                    }

                    TextEditor(text: $request)
                        .font(.body)
                        .focused($focused)
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.canopyRule))
                        .disabled(unavailableReason != nil)

                    if result == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Try").font(.caption).foregroundStyle(.secondary)
                            ForEach(examples, id: \.self) { example in
                                Button(example) { request = example }
                                    .buttonStyle(.link)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage).font(.callout).foregroundStyle(Color.canopyRust)
                    }

                    if let result { preview(result) }
                }
                .padding()
            }

            Rectangle().fill(Color.canopyRule).frame(height: 1)
            footer
        }
        .frame(width: 500, height: 540)
        .background(Color.canopyPaper)
        .onAppear { focused = true }
    }

    // MARK: Preview

    private func preview(_ result: WorkflowDraftResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.workflow.name).font(.headline)
            ForEach(Array(result.workflow.steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.kind.icon)
                        .foregroundStyle(step.kind.color).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(index + 1). \(step.kind.title)").font(.subheadline.weight(.medium))
                        Text(step.action.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let trigger = result.workflow.triggers.first {
                Label("Runs daily at \(trigger.displayTime)", systemImage: "clock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(Color.canopyRust)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.canopyRule))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            if let result {
                Button("Regenerate") { Task { await generate() } }
                    .disabled(isWorking)
                Button("Open in Editor") {
                    onDraft(result.workflow)
                    dismiss()
                }
                .buttonStyle(.canopyPrimary)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Generate") { Task { await generate() } }
                    .buttonStyle(.canopyPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || unavailableReason != nil
                              || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    private func generate() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            result = try await WorkflowAssistant.draft(from: request)
        } catch {
            result = nil
            errorMessage = error.localizedDescription
        }
    }
}
