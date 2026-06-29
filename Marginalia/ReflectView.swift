import SwiftUI

// MARK: - Reflect View
//
// Presented as a sheet from PaperView. Separate from the Notes sidebar —
// the sidebar remains lightweight capture; Reflect is intentional re-engagement.
//
// Design principles (CLAUDE.md §6):
//   - User-authored material is visually primary
//   - Model-generated prompts are visibly labeled and visually secondary
//   - No chat bubbles, no gradients, no excessive icons
//   - Calm, reading-focused — not a productivity dashboard

enum ReflectMode: String, CaseIterable {
    case recall        = "Recall"
    case revisit       = "Revisit"
    case resolve       = "Resolve"
    case closeReading  = "Close reading"
}

struct ReflectView: View {
    let paper: ZoteroPaper
    let notes: [MarginaliaNote]     // passed in so Reflect knows whether notes exist

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var selectedMode: ReflectMode = .recall
    @State private var reflections: [Reflection] = []
    @State private var currentIndex: Int = 0
    @State private var draftResponse: String = ""
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    private var openReflections: [Reflection] {
        reflections.filter { $0.status == "open" }
    }

    private var currentReflection: Reflection? {
        guard currentIndex < openReflections.count else { return nil }
        return openReflections[currentIndex]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Mode picker
                Picker("Mode", selection: $selectedMode) {
                    ForEach(ReflectMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Rectangle().fill(t.separator).frame(height: 0.5)

                // Content area
                switch selectedMode {
                case .recall:
                    recallContent
                case .revisit:
                    placeholderContent(
                        icon: "arrow.counterclockwise",
                        title: "Revisit",
                        description: "Return to notes you wrote weeks or months ago. Revisit surfaces annotations from earlier in your reading of this paper — before you had the full picture — and asks whether you still agree.",
                        status: "Coming in a future version."
                    )
                case .resolve:
                    placeholderContent(
                        icon: "questionmark.circle",
                        title: "Resolve",
                        description: "Surface your open questions and disagreements. Resolve finds notes tagged as questions or disagreements and asks you to write a follow-up — did you get an answer? Did your view change?",
                        status: "Coming in a future version."
                    )
                case .closeReading:
                    placeholderContent(
                        icon: "text.magnifyingglass",
                        title: "Close reading",
                        description: "Work through a specific section carefully. Close reading presents a passage you annotated and asks you to reconstruct the argument in your own words.",
                        status: "Coming in a future version."
                    )
                }
            }
            .background(t.bgPrimary)
            .navigationTitle("Reflect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(paper.title)
                            .font(.caption)
                            .foregroundColor(t.textSecondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(t.textSecondary)
                            .padding(6)
                            .background(t.bgSurfaceAlt)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await loadReflections() }
    }

    // MARK: - Recall content

    @ViewBuilder
    private var recallContent: some View {
        if notes.isEmpty {
            // No notes at all — calm empty state
            emptyState(
                icon: "pencil.and.outline",
                message: "Write or record a few thoughts first.\nReflect uses your notes, not the paper abstract."
            )
        } else if isLoading {
            Spacer()
            ProgressView("Loading…")
                .foregroundColor(t.textSecondary)
            Spacer()
        } else if openReflections.isEmpty {
            // Notes exist but no open recall prompts yet
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 36))
                    .foregroundColor(t.textTertiary)
                Text("No open recall prompts.")
                    .font(.headline)
                    .foregroundColor(t.textPrimary)
                Text("Generate new prompts from your notes.")
                    .font(.subheadline)
                    .foregroundColor(t.textSecondary)
                    .multilineTextAlignment(.center)
                generateButton
                Spacer()
            }
            .padding(.horizontal, 32)
        } else {
            // Show current prompt + response editor
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let reflection = currentReflection {
                        promptCard(reflection)
                        responseEditor
                        actionRow(reflection)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 20)
                    }

                    Divider().padding(.horizontal, 20)

                    generateButton
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                }
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Prompt card

    @ViewBuilder
    private func promptCard(_ reflection: Reflection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Provenance label — model-generated prompts are always labeled
            HStack(spacing: 4) {
                Image(systemName: "sparkle")
                    .font(.system(size: 10))
                Text("Suggested by Marginalia")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(t.textTertiary)

            Text(reflection.prompt)
                .font(.body)
                .foregroundColor(t.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            // Progress indicator
            if openReflections.count > 1 {
                Text("\(currentIndex + 1) of \(openReflections.count)")
                    .font(.caption)
                    .foregroundColor(t.textTertiary)
            }
        }
        .padding(16)
        .background(t.bgSurfaceAlt)
        .cornerRadius(10)
        .padding(.horizontal, 20)
    }

    // MARK: - Response editor

    @ViewBuilder
    private var responseEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your response")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(t.textSecondary)
                .padding(.horizontal, 20)

            ZStack(alignment: .topLeading) {
                if draftResponse.isEmpty {
                    Text("Write your response…")
                        .font(.callout)
                        .foregroundColor(t.textTertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }
                TextEditor(text: $draftResponse)
                    .font(.callout)
                    .foregroundColor(t.textPrimary)
                    .frame(minHeight: 140)
                    .padding(.horizontal, 16)
                    .scrollContentBackground(.hidden)
                    .background(t.bgSurface)
            }
            .background(t.bgSurface)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(t.separator, lineWidth: 0.5)
            )
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Action row

    @ViewBuilder
    private func actionRow(_ reflection: Reflection) -> some View {
        HStack(spacing: 12) {
            // Save response
            Button {
                Task { await saveResponse(reflection) }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().scaleEffect(0.75)
                    } else {
                        Text("Save response")
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(theme.accent)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(draftResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

            // Skip
            Button {
                Task { await dismiss(reflection, status: "dismissed") }
            } label: {
                Text("Skip")
                    .font(.subheadline)
                    .foregroundColor(t.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Next (without saving)
            if currentIndex < openReflections.count - 1 {
                Button {
                    draftResponse = ""
                    currentIndex += 1
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "arrow.right")
                    }
                    .font(.subheadline)
                    .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Generate button

    @ViewBuilder
    private var generateButton: some View {
        Button {
            Task { await generateNew() }
        } label: {
            HStack(spacing: 8) {
                if isGenerating {
                    ProgressView().scaleEffect(0.8)
                    Text("Generating…")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Generate new prompts")
                }
            }
            .font(.subheadline)
            .foregroundColor(isGenerating ? t.textTertiary : theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(isGenerating || notes.isEmpty)
    }

    // MARK: - Placeholder for future modes

    @ViewBuilder
    private func placeholderContent(
        icon: String,
        title: String,
        description: String,
        status: String
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(t.textTertiary)
            Text(title)
                .font(.headline)
                .foregroundColor(t.textPrimary)
            Text(description)
                .font(.callout)
                .foregroundColor(t.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Text(status)
                .font(.footnote)
                .foregroundColor(t.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundColor(t.textTertiary)
            Text(message)
                .font(.callout)
                .foregroundColor(t.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Actions

    private func loadReflections() async {
        isLoading = true
        defer { isLoading = false }
        do {
            reflections = try await BackendService.fetchReflections(paperId: paper.id)
            currentIndex = 0
            draftResponse = ""
        } catch {
            print("Could not load reflections: \(error)")
        }
    }

    private func generateNew() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let new = try await BackendService.generateReflections(paperId: paper.id, mode: "recall")
            reflections = new + reflections.filter { $0.status != "open" }
            currentIndex = 0
            draftResponse = ""
        } catch {
            errorMessage = "Could not generate prompts. Is Ollama running on your Mac?\n\(error.localizedDescription)"
        }
    }

    private func saveResponse(_ reflection: Reflection) async {
        let trimmed = draftResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await BackendService.updateReflection(
                paperId: paper.id,
                reflectionId: reflection.id,
                response: trimmed,
                status: "answered"
            )
            applyUpdate(updated)
            draftResponse = ""
            advanceToNext()
        } catch {
            errorMessage = "Could not save response: \(error.localizedDescription)"
        }
    }

    private func dismiss(_ reflection: Reflection, status: String) async {
        do {
            let updated = try await BackendService.updateReflection(
                paperId: paper.id,
                reflectionId: reflection.id,
                status: status
            )
            applyUpdate(updated)
            draftResponse = ""
            advanceToNext()
        } catch {
            print("Could not update reflection: \(error)")
        }
    }

    private func applyUpdate(_ updated: Reflection) {
        if let idx = reflections.firstIndex(where: { $0.id == updated.id }) {
            reflections[idx] = updated
        }
    }

    private func advanceToNext() {
        if currentIndex >= openReflections.count {
            currentIndex = max(0, openReflections.count - 1)
        }
    }
}
