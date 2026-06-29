import SwiftUI

// MARK: - Reading Intention Card
//
// Compact card shown at the top of the Notes sidebar.
// Both fields (reason_saved, reading_goal) are user-authored — never AI-generated.
// Displays an invitation when empty; shows content when set; edits via a small sheet.

struct ReadingIntentionCard: View {
    let paperId: String

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var context: PaperContext? = nil
    @State private var showEditor = false
    @State private var isLoading = false

    private var hasContent: Bool {
        let r = context?.reasonSaved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let g = context?.readingGoal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !r.isEmpty || !g.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section label row
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

            Rectangle()
                .fill(t.separator)
                .frame(height: 0.5)
        }
        .task { await loadContext() }
        .sheet(isPresented: $showEditor) {
            ReadingIntentionEditor(paperId: paperId, existing: context) { updated in
                context = updated
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

    private func loadContext() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
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
    }

    private func save() async {
        isSaving = true
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
            print("Could not save reading intention: \(error)")
        }
        isSaving = false
    }
}
