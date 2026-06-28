import SwiftUI

struct PaperListView: View {
    let collection: ZoteroCollection
    @Binding var selectedPaper: ZoteroPaper?

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var papers: [ZoteroPaper] = []
    @State private var isLoading = true
    @State private var searchText = ""

    var filteredPapers: [ZoteroPaper] {
        if searchText.isEmpty { return papers }
        return papers.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.authors.localizedCaseInsensitiveContains(searchText) ||
            $0.year.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading papers…")
            } else if papers.isEmpty {
                ContentUnavailableView(
                    "No papers",
                    systemImage: "tray",
                    description: Text("This collection doesn't have any papers yet.")
                )
            } else {
                List(filteredPapers, selection: $selectedPaper) { paper in
                    PaperRowView(paper: paper)
                        .tag(paper)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowSeparatorTint(t.separator)  // hairline in theme separator color
                        .listRowBackground(Color.clear)     // let bgPrimary show through
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(t.bgPrimary)                    // warm #FAFAF8, not pure white
                .searchable(text: $searchText, prompt: "Search papers…")
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.large)
        .task(id: collection.id) {
            await loadPapers()
        }
    }

    private func loadPapers() async {
        isLoading = true
        do {
            papers = try await BackendService.fetchPapers(collectionId: collection.id)
        } catch {
            print("Error loading papers: \(error)")
        }
        isLoading = false
    }
}

struct PaperRowView: View {
    let paper: ZoteroPaper
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {   // 4pt = base unit between title/authors/year
            Text(paper.title)
                .font(.subheadline)                 // 15pt regular — spec: subheadline, paper rows
                .lineLimit(2)
                .lineSpacing(2)
                .foregroundColor(t.textPrimary)

            Text(paper.authors)
                .font(.footnote)                    // 13pt regular — spec: caption = 13pt (iOS .caption = 12pt, wrong; .footnote = 13pt, correct)
                .foregroundColor(t.textSecondary)
                .lineLimit(1)

            HStack {
                Text(paper.year)
                    .font(.caption2)                // 11pt — spec: caption2, tags/badges
                    .fontWeight(.medium)
                    .foregroundColor(t.textTertiary) // year recedes furthest: primary > secondary > tertiary

                Spacer()

                if paper.hasPdf {
                    Image(systemName: "doc.fill")
                        .font(.caption2)
                        .fontWeight(.medium)         // spec: caption2 = 11 medium
                        .foregroundColor(theme.accent)
                }
            }
        }
        .padding(.vertical, 12)                     // 3× base unit — spec: card padding 12–16pt
    }
}
