import SwiftUI

// MARK: - Reading Intention Card
//
// Compact card shown at the top of the Notes sidebar.
// Both fields (reason_saved, reading_goal) are user-authored — never AI-generated.

struct ReadingIntentionCard: View {
    let paperId: String

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var context: PaperContext? = nil
    @State private var showEditor = false

    private var hasContent: Bool {
        let r = context?.reasonSaved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let g = context?.readingGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !r.isEmpty || !g.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Reading intention")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accent)
                Spacer()
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: hasContent ? "pencil" : "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if hasContent {
                VStack(alignment: .leading, spacing: 8) {
                    if let r = context?.reasonSaved, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        intentionRow(label: "Why saved", text: r)
                    }
                    if let g = context?.readingGoal, !g.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        intentionRow(label: "Looking for", text: g)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            } else {
                Button {
                    showEditor = true
                } label: {
                    Text("Why did you save this paper? What are you looking for?")
                        .font(.footnote)
                        .foregroundColor(t.textTertiary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                .buttonStyle(.plain)
            }

            Rectangle().fill(t.separator).frame(height: 0.5)
        }
        .task { await fetchContext() }
        // Re-fetch from backend whenever the editor closes — confirms the save landed.
        .onChange(of: showEditor) { _, nowShowing in
            if !nowShowing {
                Task { context = try? await BackendService.fetchContext(paperId: paperId) }
            }
        }
        .sheet(isPresented: $showEditor) {
            ReadingIntentionEditor(paperId: paperId, existing: context) { updated in
                context = updated   // optimistic local update while re-fetch is in flight
            }
        }
    }

    @ViewBuilder
    private func intentionRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(t.textTertiary)
            Text(text)
                .font(.footnote)
                .foregroundColor(t.textSecondary)
                .lineSpacing(3)
                .lineLimit(4)
        }
    }

    private func fetchContext() async {
        context = try? await BackendService.fetchContext(paperId: paperId)
    }
}

// MARK: - Reading Intention Editor Sheet

struct ReadingIntentionEditor: View {
    let paperId: String
    let existing: PaperContext?
    let onSave: (PaperContext) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var reasonSaved: String = ""
    @State private var readingGoal: String = ""
    @State private var isSaving = false
    @State private var saveError: String? = nil

    var body: some View {
        NavigationView {
            List {
                Section {
                    TextEditor(text: $reasonSaved)
                        .font(.callout)
                        .frame(minHeight: 80)
                } header: {
                    HStack {
                        Text("Why did you save this paper?")
                        Spacer()
                        VoiceDictationButton(text: $reasonSaved)
                    }
                } footer: {
                    Text("Your own words — not generated. Speak or type.")
                        .font(.caption)
                        .foregroundColor(t.textTertiary)
                }

                Section {
                    TextEditor(text: $readingGoal)
                        .font(.callout)
                        .frame(minHeight: 80)
                } header: {
                    HStack {
                        Text("What's your reading goal?")
                        Spacer()
                        VoiceDictationButton(text: $readingGoal)
                    }
                } footer: {
                    Text("A method you're looking for, a comparison, a specific question you want answered.")
                        .font(.caption)
                        .foregroundColor(t.textTertiary)
                }
            }
            .navigationTitle("Reading intention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(t.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .fontWeight(.semibold)
                        .foregroundColor(theme.accent)
                    }
                }
            }
        }
        .onAppear {
            reasonSaved = existing?.reasonSaved ?? ""
            readingGoal = existing?.readingGoal ?? ""
        }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await BackendService.upsertContext(
                paperId: paperId,
                reasonSaved: reasonSaved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : reasonSaved.trimmingCharacters(in: .whitespacesAndNewlines),
                readingGoal: readingGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : readingGoal.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSave(updated)
            dismiss()
        } catch {
            saveError = "Is your Mac backend running?\n\(error.localizedDescription)"
        }
    }
}
