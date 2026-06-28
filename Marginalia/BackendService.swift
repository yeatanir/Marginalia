import Foundation

// MARK: - Models

struct ZoteroCollection: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let paperCount: Int

    enum CodingKeys: String, CodingKey {
        case id = "key"
        case name
        case paperCount = "paper_count"
    }
}

struct ZoteroPaper: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let authors: String
    let year: String
    let abstract: String
    let hasPdf: Bool

    enum CodingKeys: String, CodingKey {
        case id = "key"
        case title
        case authors
        case year
        case abstract
        case hasPdf = "has_pdf"
    }
}

struct MarginaliaNote: Identifiable, Codable, Hashable {
    let id: String
    let paperId: String
    let page: Int
    let content: String
    let noteType: String   // "text", "voice", "ink"
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case paperId = "paper_id"
        case page
        case content
        case noteType = "note_type"
        case createdAt = "created_at"
    }
}

// MARK: - Backend Service

// Stateless networking layer. All methods are static; no observable state here.
class BackendService {

    // Default shown in Settings on first launch. User can override via ⚙ > Backend
    // without recompiling — the value is persisted in UserDefaults("backendURL").
    static let defaultBaseURL = "http://YOUR-MAC-MINI-TAILSCALE-IP:8000"

    // Computed so every networking call reads the current UserDefaults value.
    // Trailing slash is stripped defensively so path concatenation never double-slashes.
    static var baseURL: String {
        let raw = UserDefaults.standard.string(forKey: "backendURL") ?? defaultBaseURL
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    // MARK: - Collections

    static func fetchCollections() async throws -> [ZoteroCollection] {
        let url = URL(string: "\(baseURL)/collections")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ZoteroCollection].self, from: data)
    }

    // MARK: - Papers

    static func fetchPapers(collectionId: String) async throws -> [ZoteroPaper] {
        let url = URL(string: "\(baseURL)/collections/\(collectionId)/papers")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ZoteroPaper].self, from: data)
    }

    static func fetchAllPapers() async throws -> [ZoteroPaper] {
        let url = URL(string: "\(baseURL)/papers")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ZoteroPaper].self, from: data)
    }

    // MARK: - PDF

    static func pdfURL(for paperId: String) -> URL {
        URL(string: "\(baseURL)/papers/\(paperId)/pdf")!
    }

    // MARK: - Uploaded Papers

    static func fetchUploadedPapers() async throws -> [ZoteroPaper] {
        let url = URL(string: "\(baseURL)/papers/uploaded")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ZoteroPaper].self, from: data)
    }

    static func uploadPaper(pdfData: Data, title: String, authors: String, year: String) async throws -> ZoteroPaper {
        let url = URL(string: "\(baseURL)/papers/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("title", title)
        field("authors", authors)
        field("year", year)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"pdf\"; filename=\"upload.pdf\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/pdf\r\n\r\n".data(using: .utf8)!)
        body.append(pdfData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ZoteroPaper.self, from: data)
    }

    static func deleteUploadedPaper(paperId: String) async throws {
        let url = URL(string: "\(baseURL)/papers/uploaded/\(paperId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Notes

    static func fetchNotes(paperId: String) async throws -> [MarginaliaNote] {
        let url = URL(string: "\(baseURL)/papers/\(paperId)/notes")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([MarginaliaNote].self, from: data)
    }

    static func saveNote(paperId: String, page: Int, content: String, noteType: String) async throws -> MarginaliaNote {
        let url = URL(string: "\(baseURL)/papers/\(paperId)/notes")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "paper_id": paperId,
            "page": page,
            "content": content,
            "note_type": noteType
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(MarginaliaNote.self, from: data)
    }

    // MARK: - Phase 3: AI recall questions

    static func fetchQuestions(paperId: String) async throws -> [String] {
        let url = URL(string: "\(baseURL)/papers/\(paperId)/questions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        let (data, _) = try await URLSession.shared.data(for: request)
        struct QResponse: Decodable { let questions: [String] }
        return try JSONDecoder().decode(QResponse.self, from: data).questions
    }

    // MARK: - Voice Transcription

    static func transcribeAudio(audioData: Data) async throws -> String {
        let url = URL(string: "\(baseURL)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // Whisper large-v3 cold-load takes ~60s on Mac Mini

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONDecoder().decode([String: String].self, from: data)
        return result["text"] ?? ""
    }
}
