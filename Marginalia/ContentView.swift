import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var selectedCollection: ZoteroCollection? = nil
    @State private var selectedPaper: ZoteroPaper? = nil
    @State private var collections: [ZoteroCollection] = []
    @State private var uploadedPapers: [ZoteroPaper] = []
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var showSettings = false
    @State private var showUploadPicker = false
    @State private var isUploading = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // MARK: - Sidebar: Collections
            List(selection: $selectedCollection) {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading library…")
                            .font(.subheadline)
                            .foregroundColor(t.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                    .listRowSeparator(.hidden)

                } else if let error = errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cannot connect", systemImage: "wifi.slash")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(t.textSecondary)
                        Button("Retry") {
                            Task { await loadCollections() }
                        }
                        .font(.footnote)
                        .foregroundColor(theme.accent)
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 12)
                    .listRowSeparator(.hidden)

                } else {
                    Section {
                        ForEach(collections) { collection in
                            CollectionSidebarRow(
                                collection: collection,
                                isSelected: selectedCollection == collection
                            )
                            .tag(collection)
                        }
                    } header: {
                        SidebarSectionHeader("Collections")
                    }

                    Section {
                        if uploadedPapers.isEmpty && !isUploading {
                            Button {
                                showUploadPicker = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.up.doc")
                                        .font(.system(size: 14))
                                        .foregroundColor(t.textTertiary)
                                        .frame(width: 22, alignment: .center)
                                    Text("Upload a PDF")
                                        .font(.subheadline)
                                        .foregroundColor(t.textTertiary)
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                        } else {
                            ForEach(uploadedPapers) { paper in
                                Button {
                                    selectedPaper = paper
                                } label: {
                                    UploadedPaperRow(paper: paper, isSelected: selectedPaper == paper)
                                }
                                .buttonStyle(.plain)
                                .listRowSeparator(.hidden)
                                .listRowBackground(
                                    selectedPaper == paper
                                        ? RoundedRectangle(cornerRadius: 8).fill(theme.accentSoft(colorScheme))
                                        : nil
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        Task { await deleteUploadedPaper(paper) }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        if isUploading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Uploading…")
                                    .font(.footnote)
                                    .foregroundColor(t.textSecondary)
                            }
                            .padding(.vertical, 8)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        HStack {
                            SidebarSectionHeader("My PDFs")
                            Spacer()
                            Button { showUploadPicker = true } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Marginalia")
            .refreshable {
                await loadCollections()
                await loadUploadedPapers()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task {
                            await loadCollections()
                            await loadUploadedPapers()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(theme)
            }
            .fileImporter(
                isPresented: $showUploadPicker,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await uploadPDF(at: url) }
            }

        } content: {
            // MARK: - Middle: Papers List
            if let collection = selectedCollection {
                PaperListView(collection: collection, selectedPaper: $selectedPaper)
            } else {
                ContentUnavailableView(
                    "Select a collection",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Choose a collection from the sidebar to see your papers.")
                )
            }

        } detail: {
            // MARK: - Detail: PDF Reader
            if let paper = selectedPaper {
                PaperView(paper: paper, columnVisibility: $columnVisibility)
                    .id(paper.id)
            } else {
                ContentUnavailableView(
                    "Select a paper",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Tap a paper to open it and start annotating.")
                )
            }
        }
        .task {
            await loadCollections()
            await loadUploadedPapers()
        }
    }

    private func loadCollections() async {
        isLoading = true
        errorMessage = nil
        do {
            collections = try await BackendService.fetchCollections()
        } catch {
            errorMessage = "Check that your Mac Mini backend is running.\n\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadUploadedPapers() async {
        do {
            uploadedPapers = try await BackendService.fetchUploadedPapers()
        } catch {
            print("Could not load uploaded papers: \(error)")
        }
    }

    private func deleteUploadedPaper(_ paper: ZoteroPaper) async {
        do {
            try await BackendService.deleteUploadedPaper(paperId: paper.id)
            uploadedPapers.removeAll { $0.id == paper.id }
            if selectedPaper?.id == paper.id { selectedPaper = nil }
        } catch {
            print("Delete uploaded paper failed: \(error)")
        }
    }

    private func uploadPDF(at url: URL) async {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        isUploading = true
        defer { isUploading = false }

        do {
            let data = try Data(contentsOf: url)
            let raw = url.deletingPathExtension().lastPathComponent
            let title = raw.removingPercentEncoding ?? raw
            let paper = try await BackendService.uploadPaper(
                pdfData: data,
                title: title,
                authors: "",
                year: ""
            )
            uploadedPapers.insert(paper, at: 0)
        } catch {
            print("Upload failed: \(error)")
        }
    }
}

// MARK: - Uploaded paper row

private struct UploadedPaperRow: View {
    let paper: ZoteroPaper
    let isSelected: Bool

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(isSelected ? theme.accent : t.textTertiary)
                .frame(width: 22, alignment: .center)
            Text(paper.title)
                .font(.subheadline)
                .foregroundColor(t.textPrimary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Sidebar subviews (small helpers, share this file per CLAUDE.md convention)

private struct SidebarSectionHeader: View {
    let title: String
    @Environment(\.theme) var t

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(t.textTertiary)
            .kerning(0.5)
            .textCase(nil)  // suppress SwiftUI's automatic uppercasing
    }
}

private struct CollectionSidebarRow: View {
    let collection: ZoteroCollection
    let isSelected: Bool

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.accentSoft(colorScheme))
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "folder.fill" : "folder")
                .font(.system(size: 14))
                .foregroundColor(isSelected ? theme.accent : t.textTertiary)
                .frame(width: 22, alignment: .center)

            Text(collection.name)
                .font(.subheadline)            // 15pt regular — same scale as paper rows
                .foregroundColor(t.textPrimary)
                .lineLimit(1)

            Spacer()

            Text("\(collection.paperCount)")
                .font(.caption2)              // 11pt — spec: caption2, tags/badges
                .fontWeight(.medium)
                .foregroundColor(isSelected ? theme.accent : t.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(isSelected
                        ? theme.accentSoft(colorScheme)
                        : t.bgSurfaceAlt)
                )
        }
        .padding(.vertical, 12)              // 3× base unit (4pt) — spec: card padding 12–16pt
        .contentShape(Rectangle())
        .listRowBackground(selectionBackground)
        .listRowSeparator(.hidden)           // sidebar rows: no visible hairlines (Bear/Things 3)
    }
}
