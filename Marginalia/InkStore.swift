import Foundation
import PencilKit

// Ink persistence. Two storage modes:
//
// Legacy (per-page): save(_:paperId:page:) / load(paperId:page:)
//   Kept for backwards compatibility. Stroke coordinates are screen-space — not
//   recommended for new drawings.
//
// Document-level: saveDocument(_:paperId:) / loadDocument(paperId:)
//   Stores a single PKDrawing for the whole document in the coordinate space of
//   PDFView's internal document view. Because the canvas is embedded inside that
//   view, PDFKit's scroll/zoom transforms the canvas along with the PDF content,
//   so strokes are always in document space regardless of zoom level.
//
// TODO (Phase 2, CLAUDE.md §9): move ink sync to backend for cross-device access.

enum InkStore {

    // MARK: - Legacy per-page API

    static func save(_ drawing: PKDrawing, paperId: String, page: Int) {
        guard let url = pageFileURL(for: paperId, page: page) else { return }
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    static func load(paperId: String, page: Int) -> PKDrawing {
        guard let url = pageFileURL(for: paperId, page: page),
              let data = try? Data(contentsOf: url),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    // MARK: - Document-level API

    /// Persist a whole-document PKDrawing (covers all pages).
    static func saveDocument(_ drawing: PKDrawing, paperId: String) {
        guard let url = documentDrawingURL(for: paperId) else { return }
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    /// Load the stored document-level drawing; returns an empty drawing if none exists.
    static func loadDocument(paperId: String) -> PKDrawing {
        guard let url = documentDrawingURL(for: paperId),
              let data = try? Data(contentsOf: url),
              let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }

    // MARK: - Private helpers

    private static func inkDirectory() -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }
        let dir = docs.appendingPathComponent("ink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func pageFileURL(for paperId: String, page: Int) -> URL? {
        guard let dir = inkDirectory() else { return nil }
        let safe = paperId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe)-\(page).drawing")
    }

    private static func documentDrawingURL(for paperId: String) -> URL? {
        guard let dir = inkDirectory() else { return nil }
        let safe = paperId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe)-doc.drawing")
    }
}
