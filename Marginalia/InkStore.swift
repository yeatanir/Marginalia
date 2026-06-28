import Foundation
import PencilKit

// TODO: (CLAUDE.md §9, Phase 2) Move ink sync to the backend when
// handwriting→text capture is added. Currently persists on-device only.
// Drawings are in screen-coordinate space relative to the PDF view frame,
// not in PDF-page coordinate space — a Phase 2 concern when syncing to backend.

enum InkStore {

    // MARK: - Public API

    /// Persist a PKDrawing for a specific paper + page number.
    static func save(_ drawing: PKDrawing, paperId: String, page: Int) {
        guard let url = fileURL(for: paperId, page: page) else { return }
        try? drawing.dataRepresentation().write(to: url, options: .atomic)
    }

    /// Load the stored PKDrawing for a paper + page; returns an empty drawing if none exists.
    static func load(paperId: String, page: Int) -> PKDrawing {
        guard let url = fileURL(for: paperId, page: page),
              let data = try? Data(contentsOf: url),
              let drawing = try? PKDrawing(data: data) else {
            return PKDrawing()
        }
        return drawing
    }

    // MARK: - Internal

    private static func fileURL(for paperId: String, page: Int) -> URL? {
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return nil }

        let dir = docs.appendingPathComponent("ink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Zotero keys are 8-char alphanumeric, but sanitise in case other IDs appear.
        let safeId = paperId.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safeId)-\(page).drawing")
    }
}
