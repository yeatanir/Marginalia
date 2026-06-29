import SwiftUI

enum ReflectMode: String, CaseIterable {
    case recall        = "Recall"
    case revisit       = "Revisit"
    case resolve       = "Resolve"
    case closeReading  = "Close reading"
}

struct ReflectView: View {
    let paper: ZoteroPaper
    @Binding var notes: [MarginaliaNote]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var selectedMode: ReflectMode = .recall

    // Recall
    @State private var reflections: [Reflection] = []
    @State private var currentIndex: Int = 0
    @State private var draftResponse: String = ""
    @State private var isLoading = false
    @State private var isGenerating = false
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    // Revisit
    @State private var revisitIndex: Int = 0
    @State private var revisitDraft: String = ""
    @State private var isSavingRevisit = false

    // Resolve
    @State private var resolveIndex: Int = 0
    @State private var resolveDraft: String = ""
    @State private var isSavingResolve = false

    // Close reading
    @State private var closeReadingPage: Int? = nil
    @State private var closeReadingDraft: String = ""
    @State private var isSavingClose = false

    // MARK: - Computed helpers

    private var openReflections: [Reflection] {
        reflections.filter { $0.status == "open" }
    }

    private var currentReflection: Reflection? {
        guard currentIndex < openReflections.count else { return nil }
        return openReflections[currentIndex]
    }

    private var revisitNotes: [MarginaliaNote] {
        notes.sorted { $0.createdAt < $1.createdAt }
    }

    private var currentRevisitNote: MarginaliaNote? {
        guard revisitIndex < revisitNotes.count else { return nil }
        return revisitNotes[revisitIndex]
    }

    private var resolveNotes: [MarginaliaNote] {
        notes
            .filter { $0.thoughtType == "question" || $0.thoughtType == "disagreement" }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var currentResolveNote: MarginaliaNote? {
        guard resolveIndex < resolveNotes.count else { return nil }
        return resolveNotes[resolveIndex]
    }

    private var pagesWithNotes: [Int] {
        Array(Set(notes.map { $0.page })).sorted()
    }

    private var closeReadingPageNotes: [MarginaliaNote] {
        guard let page = closeReadingPage else { return [] }
        return notes.filter { $0.page == page }.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $selectedMode) {
                    ForEach(ReflectMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                Rectangle().fill(t.separator).frame(height: 0.5)

                switch selectedMode {
                case .recall:       recallContent
                case .revisit:      revisitContent
                case .resolve:      resolveContent
                case .closeReading: closeReadingContent
                }
            }
            .background(t.bgPrimary)
            .navigationTitle("Reflect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(paper.title)
                        .font(.caption)
                        .foregroundColor(t.textSecondary)
                        .lineLimit(1)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
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
        .onAppear {
            if closeReadingPage == nil { closeReadingPage = pagesWithNotes.first }
        }
    }

    // MARK: - Recall

    @ViewBuilder
    private var recallContent: some View {
        if notes.isEmpty {
            emptyState(icon: "pencil.and.outline",
                       message: "Write or record a few thoughts first.\nReflect uses your notes, not the paper abstract.")
        } else if isLoading {
            centeredProgress("Loading…")
        } else if openReflections.isEmpty {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 36)).foregroundColor(t.textTertiary)
                Text("No open recall prompts.")
                    .font(.headline).foregroundColor(t.textPrimary)
                Text("Generate new prompts from your notes.")
                    .font(.subheadline).foregroundColor(t.textSecondary).multilineTextAlignment(.center)
                generateButton
                Spacer()
            }
            .padding(.horizontal, 32)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let reflection = currentReflection {
                        promptCard(reflection)
                        responseEditorWithVoice(text: $draftResponse, placeholder: "What comes to mind…")
                        recallActionRow(reflection)
                    }
                    if let err = errorMessage {
                        Text(err).font(.caption).foregroundColor(.red).padding(.horizontal, 20)
                    }
                    Divider().padding(.horizontal, 20)
                    generateButton.padding(.horizontal, 20).padding(.bottom, 32)
                }
                .padding(.top, 20)
            }
        }
    }

    @ViewBuilder
    private func promptCard(_ reflection: Reflection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.system(size: 10))
                Text("Suggested by Marginalia").font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(t.textTertiary)

            Text(reflection.prompt)
                .font(.body).foregroundColor(t.textPrimary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if openReflections.count > 1 {
                Text("\(currentIndex + 1) of \(openReflections.count)")
                    .font(.caption).foregroundColor(t.textTertiary)
            }
        }
        .padding(16).background(t.bgSurfaceAlt).cornerRadius(10).padding(.horizontal, 20)
    }

    @ViewBuilder
    private func recallActionRow(_ reflection: Reflection) -> some View {
        HStack(spacing: 12) {
            Button {
                Task { await saveRecallResponse(reflection) }
            } label: {
                Group {
                    if isSaving { ProgressView().scaleEffect(0.75) }
                    else { Text("Save response") }
                }
                .font(.subheadline.weight(.medium)).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(theme.accent).cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(draftResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)

            Button {
                Task { await skipReflection(reflection, status: "dismissed") }
            } label: {
                Text("Skip").font(.subheadline).foregroundColor(t.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer()

            if currentIndex < openReflections.count - 1 {
                Button {
                    draftResponse = ""; currentIndex += 1
                } label: {
                    HStack(spacing: 4) { Text("Next"); Image(systemName: "arrow.right") }
                        .font(.subheadline).foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var generateButton: some View {
        Button { Task { await generateNew() } } label: {
            HStack(spacing: 8) {
                if isGenerating { ProgressView().scaleEffect(0.8); Text("Generating…") }
                else { Image(systemName: "arrow.triangle.2.circlepath"); Text("Generate new prompts") }
            }
            .font(.subheadline)
            .foregroundColor(isGenerating ? t.textTertiary : theme.accent)
        }
        .buttonStyle(.plain)
        .disabled(isGenerating || notes.isEmpty)
    }

    // MARK: - Revisit

    @ViewBuilder
    private var revisitContent: some View {
        if notes.isEmpty {
            emptyState(icon: "clock.arrow.circlepath",
                       message: "Write a few notes first.\nRevisit brings back what you thought earlier in the paper.")
        } else if revisitIndex >= revisitNotes.count {
            doneState(count: revisitNotes.count, noun: "notes") {
                revisitIndex = 0; revisitDraft = ""
            }
        } else if let note = currentRevisitNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    originalNoteCard(note, label: "You wrote on page \(note.page):")

                    Text("Do you still agree? Has your understanding changed since then?")
                        .font(.callout).foregroundColor(t.textSecondary).padding(.horizontal, 20)

                    responseEditorWithVoice(text: $revisitDraft, placeholder: "What do you think now…")

                    HStack(spacing: 12) {
                        saveButton("Save as note", isSaving: isSavingRevisit,
                                   disabled: revisitDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            Task { await saveRevisitNote(originalNote: note) }
                        }
                        skipButton { revisitDraft = ""; revisitIndex += 1 }
                        Spacer()
                        if revisitIndex < revisitNotes.count - 1 {
                            nextButton { revisitDraft = ""; revisitIndex += 1 }
                        }
                    }
                    .padding(.horizontal, 20)

                    Text("\(revisitIndex + 1) of \(revisitNotes.count)")
                        .font(.caption).foregroundColor(t.textTertiary)
                        .padding(.horizontal, 20).padding(.bottom, 32)
                }
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Resolve

    @ViewBuilder
    private var resolveContent: some View {
        if notes.isEmpty {
            emptyState(icon: "questionmark.circle",
                       message: "Write a few notes first.\nResolve surfaces your questions and disagreements.")
        } else if resolveNotes.isEmpty {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "tag").font(.system(size: 40)).foregroundColor(t.textTertiary)
                Text("No questions or disagreements.")
                    .font(.headline).foregroundColor(t.textPrimary)
                Text("When adding a note, tap the type menu and choose Question or Disagreement. Resolve will surface them here.")
                    .font(.callout).foregroundColor(t.textSecondary)
                    .multilineTextAlignment(.center).lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 32)
        } else if resolveIndex >= resolveNotes.count {
            doneState(count: resolveNotes.count, noun: "items") {
                resolveIndex = 0; resolveDraft = ""
            }
        } else if let note = currentResolveNote {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    originalNoteCard(note, label: note.thoughtType == "disagreement"
                        ? "You disagreed on page \(note.page):"
                        : "You had a question on page \(note.page):")

                    Text("Did you find an answer? Did your view change?")
                        .font(.callout).foregroundColor(t.textSecondary).padding(.horizontal, 20)

                    responseEditorWithVoice(text: $resolveDraft, placeholder: "What did you find out…")

                    HStack(spacing: 12) {
                        saveButton("Save resolution", isSaving: isSavingResolve,
                                   disabled: resolveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            Task { await saveResolveNote(originalNote: note) }
                        }
                        skipButton { resolveDraft = ""; resolveIndex += 1 }
                        Spacer()
                        if resolveIndex < resolveNotes.count - 1 {
                            nextButton { resolveDraft = ""; resolveIndex += 1 }
                        }
                    }
                    .padding(.horizontal, 20)

                    Text("\(resolveIndex + 1) of \(resolveNotes.count)")
                        .font(.caption).foregroundColor(t.textTertiary)
                        .padding(.horizontal, 20).padding(.bottom, 32)
                }
                .padding(.top, 20)
            }
        }
    }

    // MARK: - Close reading

    @ViewBuilder
    private var closeReadingContent: some View {
        if notes.isEmpty {
            emptyState(icon: "text.magnifyingglass",
                       message: "Write a few notes first.\nClose reading works through one section at a time.")
        } else {
            VStack(spacing: 0) {
                // Page picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pagesWithNotes, id: \.self) { page in
                            Button {
                                closeReadingPage = page
                                closeReadingDraft = ""
                            } label: {
                                Text("p. \(page)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(closeReadingPage == page ? .white : theme.accent)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(closeReadingPage == page ? theme.accent : theme.accentSoft(.dark))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }

                Rectangle().fill(t.separator).frame(height: 0.5)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Annotations for selected page
                        if !closeReadingPageNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your annotations on page \(closeReadingPage ?? 0)")
                                    .font(.system(size: 11, weight: .medium)).foregroundColor(t.textSecondary)
                                    .padding(.horizontal, 20)
                                ForEach(closeReadingPageNotes) { note in
                                    closeReadingNoteRow(note)
                                }
                            }
                            .padding(.top, 16)
                        }

                        Text("In your own words, what was the argument or finding on this page?")
                            .font(.callout).foregroundColor(t.textSecondary).padding(.horizontal, 20)

                        responseEditorWithVoice(text: $closeReadingDraft,
                                                placeholder: "Reconstruct the argument in your own words…")

                        HStack {
                            saveButton("Save synthesis", isSaving: isSavingClose,
                                       disabled: closeReadingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                Task { await saveCloseSynthesis() }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.bottom, 32)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func closeReadingNoteRow(_ note: MarginaliaNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if note.thoughtType != "note" {
                Text(note.thoughtType.capitalized)
                    .font(.system(size: 10, weight: .medium)).foregroundColor(theme.accent)
            }
            Text(note.content)
                .font(.callout).foregroundColor(t.textPrimary).lineSpacing(4).lineLimit(6)
        }
        .padding(12).background(t.bgSurfaceAlt).cornerRadius(10).padding(.horizontal, 20)
    }

    // MARK: - Shared subviews

    @ViewBuilder
    private func originalNoteCard(_ note: MarginaliaNote, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(t.textTertiary)
            Text(note.content)
                .font(.body).foregroundColor(t.textPrimary).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).background(t.bgSurfaceAlt).cornerRadius(10).padding(.horizontal, 20)
    }

    // Response editor with "Your response" label + mic button above a TextEditor.
    @ViewBuilder
    private func responseEditorWithVoice(text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your response")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(t.textSecondary)
                Spacer()
                VoiceDictationButton(text: text)
            }
            .padding(.horizontal, 20)

            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.callout).foregroundColor(t.textTertiary)
                        .padding(.horizontal, 20).padding(.top, 8)
                }
                TextEditor(text: text)
                    .font(.callout).foregroundColor(t.textPrimary)
                    .frame(minHeight: 120)
                    .padding(.horizontal, 16)
                    .scrollContentBackground(.hidden)
            }
            .background(t.bgSurface)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.separator, lineWidth: 0.5))
            .padding(.horizontal, 20)
        }
    }

    // Primary save button — shared across modes.
    @ViewBuilder
    private func saveButton(_ label: String, isSaving: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isSaving { ProgressView().scaleEffect(0.75) }
                else { Text(label) }
            }
            .font(.subheadline.weight(.medium)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(theme.accent).cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(disabled || isSaving)
    }

    @ViewBuilder
    private func skipButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Skip").font(.subheadline).foregroundColor(t.textSecondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func nextButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Text("Next"); Image(systemName: "arrow.right") }
                .font(.subheadline).foregroundColor(theme.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func emptyState(icon: String, message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon).font(.system(size: 40)).foregroundColor(t.textTertiary)
            Text(message)
                .font(.callout).foregroundColor(t.textSecondary)
                .multilineTextAlignment(.center).lineSpacing(4)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private func doneState(count: Int, noun: String, onReset: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundColor(t.textTertiary)
            Text("You've gone through all \(count) \(noun).")
                .font(.headline).foregroundColor(t.textPrimary)
            Button { onReset() } label: {
                Text("Start over").font(.subheadline).foregroundColor(theme.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    @ViewBuilder
    private func centeredProgress(_ label: String) -> some View {
        VStack { Spacer(); ProgressView(label).foregroundColor(t.textSecondary); Spacer() }
    }

    // MARK: - Recall async

    private func loadReflections() async {
        isLoading = true; defer { isLoading = false }
        do {
            reflections = try await BackendService.fetchReflections(paperId: paper.id)
            currentIndex = 0; draftResponse = ""
        } catch { print("Could not load reflections: \(error)") }
    }

    private func generateNew() async {
        isGenerating = true; errorMessage = nil; defer { isGenerating = false }
        do {
            let new = try await BackendService.generateReflections(paperId: paper.id, mode: "recall")
            reflections = new + reflections.filter { $0.status != "open" }
            currentIndex = 0; draftResponse = ""
        } catch {
            errorMessage = "Could not generate prompts. Is Ollama running on your Mac?\n\(error.localizedDescription)"
        }
    }

    private func saveRecallResponse(_ reflection: Reflection) async {
        let trimmed = draftResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true; defer { isSaving = false }
        do {
            let updated = try await BackendService.updateReflection(
                paperId: paper.id, reflectionId: reflection.id, response: trimmed, status: "answered")
            if let idx = reflections.firstIndex(where: { $0.id == updated.id }) { reflections[idx] = updated }
            draftResponse = ""
            if currentIndex >= openReflections.count { currentIndex = max(0, openReflections.count - 1) }
        } catch { errorMessage = "Could not save response: \(error.localizedDescription)" }
    }

    private func skipReflection(_ reflection: Reflection, status: String) async {
        do {
            let updated = try await BackendService.updateReflection(
                paperId: paper.id, reflectionId: reflection.id, status: status)
            if let idx = reflections.firstIndex(where: { $0.id == updated.id }) { reflections[idx] = updated }
            draftResponse = ""
            if currentIndex >= openReflections.count { currentIndex = max(0, openReflections.count - 1) }
        } catch { print("Could not update reflection: \(error)") }
    }

    // MARK: - Revisit async

    private func saveRevisitNote(originalNote: MarginaliaNote) async {
        let trimmed = revisitDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSavingRevisit = true; defer { isSavingRevisit = false }
        do {
            let saved = try await BackendService.saveNote(
                paperId: paper.id, page: originalNote.page,
                content: trimmed, noteType: "text", thoughtType: "connection")
            notes.insert(saved, at: 0)
            revisitDraft = ""; revisitIndex += 1
        } catch { print("Could not save revisit note: \(error)") }
    }

    // MARK: - Resolve async

    private func saveResolveNote(originalNote: MarginaliaNote) async {
        let trimmed = resolveDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSavingResolve = true; defer { isSavingResolve = false }
        do {
            let saved = try await BackendService.saveNote(
                paperId: paper.id, page: originalNote.page,
                content: trimmed, noteType: "text", thoughtType: "note")
            notes.insert(saved, at: 0)
            resolveDraft = ""; resolveIndex += 1
        } catch { print("Could not save resolve note: \(error)") }
    }

    // MARK: - Close reading async

    private func saveCloseSynthesis() async {
        let trimmed = closeReadingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let page = closeReadingPage else { return }
        isSavingClose = true; defer { isSavingClose = false }
        do {
            let saved = try await BackendService.saveNote(
                paperId: paper.id, page: page,
                content: trimmed, noteType: "text", thoughtType: "note")
            notes.insert(saved, at: 0)
            closeReadingDraft = ""
        } catch { print("Could not save synthesis: \(error)") }
    }
}
