import SwiftUI
import PDFKit
import PencilKit
import AVFoundation
import Vision

// MARK: - PDF Load State

enum PDFLoadState { case loading, loaded, failed }

// Shared reference so PaperView can reach the live PKCanvasView for the current PDF page.
// canvas is computed dynamically via a closure set by the coordinator — avoids stale cached
// references when multiple pages are visible simultaneously.
final class CanvasRef {
    var lookup: (() -> PKCanvasView?)?
    var canvas: PKCanvasView? { lookup?() }
}

// MARK: - Main Paper View

struct PaperView: View {
    let paper: ZoteroPaper
    @Binding var columnVisibility: NavigationSplitViewVisibility

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var notes: [MarginaliaNote] = []
    @State private var showNotesSidebar = false
    @State private var showVoiceRecorder = false
    @State private var currentPage = 1
    @State private var newNoteText = ""
    @State private var pdfLoadState: PDFLoadState = .loading
    @State private var pdfRetryToken = 0
    @State private var canvasRef = CanvasRef()
    @State private var isRecognizing = false

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - PDF + Pencil Canvas
            ZStack(alignment: .bottomTrailing) {
                if pdfLoadState == .failed {
                    ContentUnavailableView {
                        Label("PDF Not Available", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The PDF couldn't be loaded from your Mac Mini backend.")
                    } actions: {
                        Button("Retry") {
                            pdfLoadState = .loading
                            pdfRetryToken += 1
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ZStack {
                        PDFAnnotationView(
                            pdfURL: BackendService.pdfURL(for: paper.id),
                            paperId: paper.id,
                            currentPage: $currentPage,
                            loadState: $pdfLoadState,
                            canvasRef: canvasRef
                        )
                        .id(pdfRetryToken)

                        if pdfLoadState == .loading {
                            Rectangle()
                                .fill(t.bgPrimary)
                                .overlay {
                                    VStack(spacing: 12) {
                                        ProgressView()
                                        Text("Loading PDF…")
                                            .font(.subheadline)
                                            .foregroundColor(t.textSecondary)
                                    }
                                }
                        }
                    }
                }

                // FABs + voice panel — hidden during load error
                if pdfLoadState != .failed {
                    VStack(alignment: .trailing, spacing: 12) {
                        // Voice recorder panel — floats above the FABs, stays compact
                        if showVoiceRecorder {
                            VoiceRecorderPanel(
                                paper: paper,
                                currentPage: currentPage,
                                onNoteSaved: { note in
                                    notes.insert(note, at: 0)
                                },
                                onDismiss: {
                                    withAnimation(.spring(response: 0.3)) {
                                        showVoiceRecorder = false
                                    }
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        // FABs
                        VStack(spacing: 12) {
                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    showVoiceRecorder.toggle()
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(showVoiceRecorder
                                            ? theme.accent
                                            : t.bgSurface.opacity(0.9))
                                        .frame(width: 52, height: 52)
                                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                                    Image(systemName: "mic.fill")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundColor(showVoiceRecorder ? .white : theme.accent)
                                }
                            }

                            Button {
                                withAnimation(.spring(response: 0.3)) {
                                    showNotesSidebar.toggle()
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(t.bgSurface.opacity(0.9))
                                        .frame(width: 52, height: 52)
                                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 2)
                                    Image(systemName: showNotesSidebar ? "sidebar.right" : "note.text")
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundColor(theme.accent)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }

            // MARK: - Notes Sidebar (slides in from right)
            if showNotesSidebar {
                NotesSidebarView(
                    paper: paper,
                    notes: $notes,
                    currentPage: currentPage,
                    newNoteText: $newNoteText,
                    onSaveNote: saveTextNote
                )
                .frame(width: 320)
                .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(paper.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    withAnimation {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: columnVisibility == .detailOnly ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 16) {
                    if isRecognizing {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        // Re-show PKToolPicker (pen/eraser/colour palette).
                        // Tap this if the palette disappeared after scrolling.
                        Button {
                            (canvasRef.canvas as? InkCanvas)?.activatePicker()
                        } label: {
                            Image(systemName: "pencil.tip")
                        }
                        .help("Show drawing tools")

                        // Convert ink strokes → searchable text note (Apple Vision ML, on-device)
                        Button {
                            Task { await recognizeInkOnCurrentPage() }
                        } label: {
                            Image(systemName: "text.viewfinder")
                        }
                        .help("Save handwriting as a text note (Apple on-device ML)")

                        // Clear all ink on the current page
                        Button {
                            canvasRef.canvas?.drawing = PKDrawing()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Clear ink on this page")
                    }
                    Text("p. \(currentPage)")
                        .font(.caption)
                        .foregroundColor(t.textSecondary)
                }
            }
        }
        .task {
            await loadNotes()
        }
    }

    private func loadNotes() async {
        do {
            notes = try await BackendService.fetchNotes(paperId: paper.id)
        } catch {
            print("Could not load notes: \(error)")
        }
    }

    private func recognizeInkOnCurrentPage() async {
        guard let canvas = canvasRef.canvas,
              !canvas.drawing.strokes.isEmpty else { return }
        isRecognizing = true
        defer { isRecognizing = false }

        let drawing = canvas.drawing

        // Each canvas is sized by PDFKit to exactly one PDF page via PDFPageOverlayViewProvider.
        // canvas.bounds IS the page area — no contentOffset arithmetic needed.
        let bounds = canvas.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 768, height: 1024) : canvas.bounds

        // Render ink to image (white background for better Vision accuracy)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            drawing.image(from: bounds, scale: 2).draw(in: bounds)
        }
        guard let cgImage = image.cgImage else { return }

        let text: String = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let note = try await BackendService.saveNote(
                paperId: paper.id,
                page: currentPage,
                content: text,
                noteType: "ink"
            )
            notes.insert(note, at: 0)
        } catch {
            print("Could not save ink note: \(error)")
        }
    }

    private func saveTextNote() async {
        guard !newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            let note = try await BackendService.saveNote(
                paperId: paper.id,
                page: currentPage,
                content: newNoteText,
                noteType: "text"
            )
            notes.insert(note, at: 0)
            newNoteText = ""
        } catch {
            print("Could not save note: \(error)")
        }
    }
}

// MARK: - PDF View with PencilKit overlay

// Subclasses only to get reliable didMoveToWindow timing for tool picker.
// No hitTest override — touch routing is NOT done here.
private class InkCanvas: PKCanvasView {
    private let toolPicker: PKToolPicker

    init(toolPicker: PKToolPicker) {
        self.toolPicker = toolPicker
        super.init(frame: .zero)
        toolPicker.addObserver(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // Two async hops: first lets SwiftUI finish its layout pass,
        // second lets the window finish becoming key.
        // Order matters: becomeFirstResponder() must succeed BEFORE
        // setVisible so PKToolPicker knows who is showing it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            _ = self.becomeFirstResponder()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toolPicker.setVisible(true, forFirstResponder: self)
            }
        }
    }

    // Call this from a toolbar button so the user can re-show the picker
    // after tapping the PDF (which causes the canvas to lose first responder).
    func activatePicker() {
        _ = becomeFirstResponder()
        toolPicker.setVisible(true, forFirstResponder: self)
    }

    func reactivateAfterReparent() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.becomeFirstResponder()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.toolPicker.setVisible(true, forFirstResponder: self)
            }
        }
    }

}

struct PDFAnnotationView: UIViewRepresentable {
    let pdfURL: URL
    let paperId: String
    @Binding var currentPage: Int
    @Binding var loadState: PDFLoadState
    let canvasRef: CanvasRef

    func makeCoordinator() -> Coordinator {
        Coordinator(currentPage: $currentPage, loadState: $loadState, paperId: paperId)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true

        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        // isInMarkupMode tells PDFView it is hosting an annotation layer. It suppresses
        // PDFView's internal pencil-proximity behavior — the text-selection preparation,
        // cursor tracking, and Scribble activation that PDFKit triggers when Apple Pencil
        // approaches the screen — which is the root cause of strokes disappearing on hover.
        pdfView.isInMarkupMode = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        let toolPicker = PKToolPicker()
        let coordinator = context.coordinator
        coordinator.pdfView = pdfView
        coordinator.toolPicker = toolPicker

        // Dynamic lookup: always returns the canvas for the page currently on screen.
        // Evaluated at button-press time — no cached reference, no timing issues.
        canvasRef.lookup = { [weak coordinator] in
            coordinator?.currentPageCanvas()
        }

        // pageOverlayViewProvider must be set BEFORE assigning the document so PDFKit
        // can call overlayViewFor on the first visible pages during initial layout.
        pdfView.pageOverlayViewProvider = coordinator

        URLSession.shared.dataTask(with: pdfURL) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("[PDF] Load error: \(error.localizedDescription)")
                    coordinator.loadState = .failed
                    return
                }
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    print("[PDF] HTTP \(http.statusCode) — no PDF for \(paperId)")
                    coordinator.loadState = .failed
                    return
                }
                guard let data = data, let document = PDFDocument(data: data) else {
                    print("[PDF] Invalid PDF data for \(paperId)")
                    coordinator.loadState = .failed
                    return
                }
                pdfView.document = document
                coordinator.loadState = .loaded
            }
        }.resume()

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // PDFAnnotationView is always re-created via .id(paper.id) in PaperView,
        // so this is only called for binding updates (currentPage, loadState).
        // No PDF reload needed here.
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.cleanup()
    }

    // Coordinator conforms to PDFPageOverlayViewProvider — Apple's official API
    // (iOS 16+) for overlaying annotation views on each PDF page. PDFKit sizes,
    // positions, and rotates each overlay automatically. Combined with
    // pdfView.isInMarkupMode = true this is the standard approach used by annotation
    // apps; it eliminates the need for any gesture-recognizer hacks or KVO on
    // contentSize, and crucially suppresses the pencil-proximity behavior in PDFView
    // that was causing ink strokes to disappear on Apple Pencil hover.
    class Coordinator: NSObject, PKCanvasViewDelegate, PDFPageOverlayViewProvider {
        @Binding var currentPage: Int
        @Binding var loadState: PDFLoadState
        let paperId: String
        var pdfView: PDFView?
        var toolPicker: PKToolPicker?
        var lastPage: Int = 1

        // One canvas per PDF page — created lazily as pages scroll into view.
        private var pageCanvases: [PDFPage: InkCanvas] = [:]
        // Maps ObjectIdentifier(canvas) → 1-based page index for per-page InkStore saves.
        private var canvasPageIndex: [ObjectIdentifier: Int] = [:]

        init(currentPage: Binding<Int>, loadState: Binding<PDFLoadState>, paperId: String) {
            _currentPage = currentPage
            _loadState = loadState
            self.paperId = paperId
        }

        func cleanup() {
            // PDFPageOverlayViewProvider lifecycle is owned by PDFKit — nothing to tear down.
        }

        func currentPageCanvas() -> PKCanvasView? {
            guard let page = pdfView?.currentPage else { return nil }
            return pageCanvases[page]
        }

        // MARK: - PDFPageOverlayViewProvider

        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            if let existing = pageCanvases[page] { return existing }
            guard let toolPicker else { return nil }

            let canvas = InkCanvas(toolPicker: toolPicker)
            canvas.drawingPolicy = .pencilOnly   // pencil draws; fingers pass through to PDF scroll
            canvas.isScrollEnabled = false
            canvas.isOpaque = false
            canvas.backgroundColor = .clear
            canvas.pinchGestureRecognizer?.isEnabled = false
            canvas.delegate = self

            let pageIndex = (view.document?.index(for: page) ?? 0) + 1
            canvas.drawing = InkStore.load(paperId: paperId, page: pageIndex)
            canvasPageIndex[ObjectIdentifier(canvas)] = pageIndex
            pageCanvases[page] = canvas
            return canvas
        }

        func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? InkCanvas else { return }
            canvas.reactivateAfterReparent()
        }

        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? InkCanvas,
                  let pageIndex = canvasPageIndex[ObjectIdentifier(canvas)] else { return }
            let drawing = canvas.drawing
            let pid = paperId
            DispatchQueue.global(qos: .background).async {
                InkStore.save(drawing, paperId: pid, page: pageIndex)
            }
        }

        // MARK: - Page tracking

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? PDFView,
                  let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let newPage = document.index(for: page) + 1
            guard newPage != lastPage else { return }
            lastPage = newPage
            currentPage = newPage
        }

        // MARK: - Drawing persistence

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let pageIndex = canvasPageIndex[ObjectIdentifier(canvasView)] else { return }
            let drawing = canvasView.drawing
            let pid = paperId
            DispatchQueue.global(qos: .background).async {
                InkStore.save(drawing, paperId: pid, page: pageIndex)
            }
        }
    }
}

// MARK: - Notes Sidebar

struct NotesSidebarView: View {
    let paper: ZoteroPaper
    @Binding var notes: [MarginaliaNote]
    let currentPage: Int
    @Binding var newNoteText: String
    let onSaveNote: () async -> Void

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var questions: [String] = []
    @State private var isLoadingQuestions = false
    @State private var showQuestions = false
    @State private var noteToEdit: MarginaliaNote? = nil
    @State private var editContent: String = ""
    @State private var noteToDelete: MarginaliaNote? = nil

    var notesForCurrentPage: [MarginaliaNote] {
        notes.filter { $0.page == currentPage }
    }

    var otherNotes: [MarginaliaNote] {
        notes.filter { $0.page != currentPage }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack {
                Text("Notes")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await loadQuestions() }
                } label: {
                    if isLoadingQuestions {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Label("Quiz me", systemImage: "brain")
                            .font(.caption)
                            .foregroundColor(theme.accent)
                    }
                }
                .buttonStyle(.plain)
                .disabled(notes.isEmpty || isLoadingQuestions)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(t.bgSurfaceAlt)

            if showQuestions && !questions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(questions, id: \.self) { q in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(theme.accent)
                                .font(.caption)
                                .padding(.top, 2)
                            Text(q)
                                .font(.callout)
                                .foregroundColor(t.textPrimary)
                                .lineSpacing(3)
                        }
                    }
                }
                .padding(12)
                .background(theme.accentSoft(.dark))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // Themed hairline separator (0.5pt, spec: "Hairline separators over heavy dividers")
            Rectangle()
                .fill(t.separator)

            // Themed hairline separator (0.5pt, spec: "Hairline separators over heavy dividers")
            Rectangle()
                .fill(t.separator)
                .frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {   // 4× base unit section gap

                    // Quick text note input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add note — page \(currentPage)")
                            .font(.footnote)                // 13pt — spec: caption = 13pt
                            .foregroundColor(t.textSecondary)

                        HStack(alignment: .bottom, spacing: 8) {
                            TextField("Type a note…", text: $newNoteText, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)             // 16pt — spec: body, note content
                                .lineLimit(3...6)

                            Button {
                                Task { await onSaveNote() }
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(theme.accent)
                            }
                            .disabled(newNoteText.isEmpty)
                        }
                    }
                    .padding(12)
                    .background(t.bgSurfaceAlt)
                    .cornerRadius(10)                       // spec: 10pt cards
                    .padding(.horizontal, 16)               // 4× base unit
                    .padding(.top, 12)

                    // Notes on current page
                    if !notesForCurrentPage.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("On this page")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.accent)
                                .padding(.horizontal, 16)

                            ForEach(notesForCurrentPage) { note in
                                NoteCardView(note: note) {
                                    noteToEdit = note
                                    editContent = note.content
                                } onDelete: {
                                    noteToDelete = note
                                }
                            }
                        }
                    }

                    // Other notes
                    if !otherNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Other pages")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(t.textSecondary)
                                .padding(.horizontal, 16)

                            ForEach(otherNotes) { note in
                                NoteCardView(note: note) {
                                    noteToEdit = note
                                    editContent = note.content
                                } onDelete: {
                                    noteToDelete = note
                                }
                            }
                        }
                    }

                    if notes.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "pencil.and.outline")
                                .font(.system(size: 36))
                                .foregroundColor(t.textTertiary)    // spec: textTertiary = hints
                            Text("No notes yet.\nWrite on the PDF or use the mic.")
                                .font(.footnote)                    // 13pt
                                .foregroundColor(t.textTertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .background(t.bgSurface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(t.separator)
                .frame(width: 0.5)
        }
        // Edit sheet
        .sheet(item: $noteToEdit) { note in
            NavigationView {
                TextEditor(text: $editContent)
                    .padding()
                    .font(.callout)
                    .navigationTitle("Edit Note")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") { noteToEdit = nil }
                        }
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Save") {
                                Task { await saveEdit(note) }
                            }
                            .fontWeight(.semibold)
                            .disabled(editContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        // Delete confirmation
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let note = noteToDelete { Task { await deleteNote(note) } }
            }
            Button("Cancel", role: .cancel) { noteToDelete = nil }
        }
    }

    private func saveEdit(_ note: MarginaliaNote) async {
        let trimmed = editContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let updated = try await BackendService.updateNote(paperId: paper.id, noteId: note.id, content: trimmed)
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx] = updated
            }
            noteToEdit = nil
        } catch {
            print("Update note failed: \(error)")
        }
    }

    private func deleteNote(_ note: MarginaliaNote) async {
        do {
            try await BackendService.deleteNote(paperId: paper.id, noteId: note.id)
            notes.removeAll { $0.id == note.id }
        } catch {
            print("Delete note failed: \(error)")
        }
        noteToDelete = nil
    }

    private func loadQuestions() async {
        isLoadingQuestions = true
        defer { isLoadingQuestions = false }
        do {
            questions = try await BackendService.fetchQuestions(paperId: paper.id)
            showQuestions = true
        } catch {
            print("Questions failed: \(error)")
        }
    }
}

// MARK: - Note Card

struct NoteCardView: View {
    let note: MarginaliaNote
    let onEdit: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    private var isHandwritten: Bool {
        note.noteType == "voice" || note.noteType == "ink"
    }

    private var iconName: String {
        switch note.noteType {
        case "voice": return "mic.fill"
        case "ink":   return "pencil"
        default:      return "text.alignleft"
        }
    }

    private var typeLabel: String {
        switch note.noteType {
        case "voice": return "Voice"
        case "ink":   return "Ink"
        default:      return "Text"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {       // 2× base unit within card

            // Note-type icon + label in accent, page number recedes to textTertiary
            HStack(spacing: 5) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accent)
                Text(typeLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accent)
                Spacer()
                Text("p. \(note.page)")
                    .font(.caption2)
                    .foregroundColor(t.textTertiary)    // page is tertiary metadata
            }

            // Content: 16pt regular (spec: body, note content).
            // Voice/ink use .serif to feel distinct from UI chrome (spec §6.3).
            Text(note.content)
                .font(.callout)                         // 16pt regular — spec: body = 16
                .fontDesign(isHandwritten ? .serif : .default)
                .foregroundColor(t.textPrimary)
                .lineSpacing(4)                         // spec: generous lineSpacing for body/notes
                .lineLimit(6)
        }
        .padding(12)
        .background(t.bgSurfaceAlt)
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .contextMenu {
            Button { onEdit() } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Voice Recorder Sheet

// Compact floating voice recorder panel. Appears above the mic FAB — does not
// cover the reading content or require the user to dismiss a full-screen sheet.
struct VoiceRecorderPanel: View {
    let paper: ZoteroPaper
    let currentPage: Int
    let onNoteSaved: (MarginaliaNote) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject var theme: ThemeManager
    @Environment(\.theme) var t

    @State private var isRecording = false
    @State private var isTranscribing = false
    @State private var transcribedText = ""
    @State private var isTextExpanded = false
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Header row ──────────────────────────────────────────
            HStack(spacing: 8) {
                // Status indicator
                if isTranscribing {
                    ProgressView().scaleEffect(0.75)
                    Text("Transcribing…")
                        .font(.subheadline)
                        .foregroundColor(t.textSecondary)
                } else if isRecording {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording · p.\(currentPage)")
                        .font(.subheadline)
                        .foregroundColor(.red)
                } else if !transcribedText.isEmpty {
                    Image(systemName: "text.bubble.fill")
                        .font(.subheadline)
                        .foregroundColor(theme.accent)
                    Text("Review · p.\(currentPage)")
                        .font(.subheadline)
                        .foregroundColor(t.textPrimary)
                } else {
                    Image(systemName: "mic")
                        .font(.subheadline)
                        .foregroundColor(theme.accent)
                    Text("Voice note · p.\(currentPage)")
                        .font(.subheadline)
                        .foregroundColor(t.textSecondary)
                }

                Spacer()

                // Record / stop (hidden once transcription appears)
                if transcribedText.isEmpty {
                    Button {
                        if isRecording { stopRecording() } else { startRecording() }
                    } label: {
                        Image(systemName: isRecording ? "stop.fill" : "record.circle")
                            .font(.system(size: 22))
                            .foregroundColor(isRecording ? .red : theme.accent)
                    }
                    .disabled(isTranscribing)
                }

                // Close / dismiss
                Button {
                    if isRecording { stopRecording() }
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(t.textTertiary)
                        .padding(6)
                        .background(t.bgSurfaceAlt)
                        .clipShape(Circle())
                }
            }

            // ── Transcription review ─────────────────────────────────
            if !transcribedText.isEmpty {
                if isTextExpanded {
                    TextEditor(text: $transcribedText)
                        .font(.subheadline)
                        .frame(height: 130)
                        .padding(8)
                        .background(t.bgSurfaceAlt)
                        .cornerRadius(8)
                } else {
                    Text(transcribedText)
                        .font(.subheadline)
                        .lineLimit(3)
                        .foregroundColor(t.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) { isTextExpanded = true }
                        }
                }

                HStack(spacing: 10) {
                    Button("Discard") {
                        transcribedText = ""
                        isTextExpanded = false
                    }
                    .font(.subheadline)
                    .foregroundColor(t.textSecondary)

                    Spacer()

                    if !isTextExpanded {
                        Button("Edit") {
                            withAnimation(.easeInOut(duration: 0.2)) { isTextExpanded = true }
                        }
                        .font(.subheadline)
                        .foregroundColor(theme.accent)
                    }

                    Button("Save") {
                        Task { await saveNote() }
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(theme.accent)
                    .cornerRadius(8)
                }
            }

            // ── Error ────────────────────────────────────────────────
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
        }
        .padding(16)
        .frame(width: 290)
        .background(t.bgSurface.opacity(0.97))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
    }

    // MARK: - Recording

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice_note_\(UUID().uuidString).m4a")
            recordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.record()
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        Task { await transcribeRecording() }
    }

    private func transcribeRecording() async {
        guard let url = recordingURL else { return }
        isTranscribing = true
        do {
            let audioData = try Data(contentsOf: url)
            transcribedText = try await BackendService.transcribeAudio(audioData: audioData)
        } catch {
            errorMessage = "Transcription failed. Is the Mac Mini backend running?\n\(error.localizedDescription)"
        }
        isTranscribing = false
    }

    private func saveNote() async {
        do {
            let note = try await BackendService.saveNote(
                paperId: paper.id,
                page: currentPage,
                content: transcribedText,
                noteType: "voice"
            )
            onNoteSaved(note)
            onDismiss()
        } catch {
            errorMessage = "Could not save note: \(error.localizedDescription)"
        }
    }
}
