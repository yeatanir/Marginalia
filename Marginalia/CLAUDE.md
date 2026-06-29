# CLAUDE.md — Marginalia

> Instructions for Claude Code. Read this fully before editing any file.
> This file is the source of truth for architecture, conventions, and design.
> When you make a structural change, UPDATE THIS FILE in the same commit.

---

## 1. What Marginalia is

An iPad app for reading research papers the way researchers actually read them:
pen in hand, writing in the margins. It fights the "illusion of understanding"
by making annotations **persist, become searchable, and resurface** instead of
dying inside a PDF.

**Core principle:** the AI never thinks *for* the user. It helps the user think
better. No auto-summaries that replace reading. Capture first; intelligence later.

**Anti-goals (do NOT build these without explicit instruction):**
- Paper-scraping / feed of new papers
- Auto-summarization that substitutes for reading the paper
- Any cloud dependency or paid API. Everything runs free on the user's hardware.

---

## 2. Hardware & Network Topology

```
┌─────────────┐   Tailscale    ┌──────────────────┐   Tailscale   ┌────────────────────┐
│    iPad     │ ─────────────► │  MacBook Pro     │ ────────────► │   Mac Mini (M4)    │
│ (runs app)  │                │  M5 Max, 64GB    │               │   16GB RAM         │
│             │                │  Xcode — BUILD   │               │   ALWAYS-ON SERVER │
└─────────────┘                │  HERE ONLY       │               │                    │
       │                       └──────────────────┘               │  FastAPI :8000     │
       │                                                          │  Whisper large-v3  │
       └──────────── Tailscale, talks directly to ───────────────►│  Ollama (later)    │
                     Mac Mini :8000 at runtime                     │  SQLite notes db   │
                                                                   │  Zotero storage    │
                                                                   └────────────────────┘
```

**Critical facts:**
- The MacBook Pro is for development ONLY. It is NOT a runtime backend. Never
  assume it is reachable when the app is running.
- The iPad app talks to the **Mac Mini's Tailscale IP** at runtime.
- The Mac Mini is the only always-on machine. All server logic lives there.
- Backend base URL is user-configurable in ⚙ > Backend (no recompile needed).
  It persists via `UserDefaults("backendURL")`. `BackendService.baseURL` reads
  this at every call; `BackendService.defaultBaseURL` is the compile-time fallback.

---

## 3. Full Stack

### Frontend — SwiftUI, iOS/iPadOS 26.5, Swift
- Bundle ID: `com.yeatanir.Marginalia`
- PDF rendering: `PDFKit`
- Pencil annotation: `PencilKit` (PKCanvasView) — native, on-device
- Handwriting→text: Apple on-device ML (Scribble / `PKToolPicker`), offline
- Voice recording: `AVFoundation` (AVAudioRecorder, m4a/AAC)
- Networking: `URLSession` async/await, no third-party libs
- Backend URL: runtime-configurable via ⚙ > Backend, persisted in `UserDefaults("backendURL")`.
  `BackendService.baseURL` is a computed `var` that reads this at every call site, so the
  Mac Mini's Tailscale IP can be changed in Settings without recompiling.
- State: `@StateObject` / `@ObservableObject`, no external state libs

### Backend — Python on Mac Mini
- `FastAPI` + `uvicorn`, host `0.0.0.0`, port `8000`
- Zotero access: `pyzotero` (read-only API key)
- Transcription: `faster-whisper`, model `large-v3`, device cpu / int8
  (chosen for Indian-accented English + scientific vocabulary)
- Notes storage: `sqlite3`, db at `~/.marginalia/notes.db`
- PDFs: read from local Zotero storage `~/Zotero/storage`, fallback to Zotero web API
- Later: `Ollama` at `localhost:11434` for the spaced-interrogation engine

### Why these choices
- No paid services, no Apple Developer Program needed (run on own device).
- Whisper local because Apple's recognizer fails on Indian-accented technical speech.
- SQLite because notes are personal, small, and must survive offline.

### Zotero PDF sourcing — IMPORTANT, do not "fix" this
Zotero desktop runs ONLY on the MacBook (to avoid dual-instance sync conflicts).
The Mac Mini does NOT run Zotero. PDFs reach the Mac Mini via **Syncthing**,
one-way (MacBook → Mac Mini), as a read-only mirror of `~/Zotero/storage`.
- Metadata (collections, titles, abstracts): Zotero Web API — works regardless
  of which machine is awake.
- PDF files: read from the synced read-only mirror at `ZOTERO_STORAGE_PATH`.
- Fallback: if a PDF isn't in the mirror, backend tries the Zotero Web API
  (`zot.file`), which only works if Zotero file sync is enabled (300MB free cap).
Do not add a requirement to run Zotero on the Mac Mini, and do not switch PDF
delivery to a paid Zotero storage tier. The Syncthing mirror is the intended,
free, unlimited path.

---

## 4. File Map & Responsibilities

### iPad app — `Marginalia/Marginalia/`
| File | Responsibility | Don't put here |
|---|---|---|
| `MarginaliaApp.swift` | App entry, injects `ThemeManager` into environment | UI logic |
| `ContentView.swift` | `NavigationSplitView` 3-column shell, loads collections | Paper/PDF logic |
| `PaperListView.swift` | Middle column: papers in a collection, search | Networking models |
| `PaperView.swift` | Detail: PDF + PencilKit canvas + voice + notes sidebar + Reflect sheet trigger | Backend definitions |
| `BackendService.swift` | ALL networking + Codable models. Single source for API | View code |
| `Theme.swift` | ThemeManager, AccentPalette, Theme tokens, SettingsView | Business logic |
| `InkStore.swift` | Per-page `PKDrawing` persistence keyed by `paperId-page`; Phase 1 on-device only (see §9 Phase 2 for backend sync) | UI code |
| `ReadingIntentionView.swift` | `ReadingIntentionCard` (compact sidebar card) + `ReadingIntentionEditor` sheet. User-authored reason_saved / reading_goal — never AI-generated | Backend or model definitions |
| `ReflectView.swift` | Full Reflect sheet: mode tabs (Recall/Revisit/Resolve/Close reading), prompt card, response editor, generate button. Recall mode is fully implemented; others are polished placeholders | Note capture UI |

### Backend — repo root
| File | Responsibility |
|---|---|
| `marginalia_backend.py` | FastAPI app, all routes, Zotero, Whisper, SQLite |
| `README.md` | Human setup guide |
| `CLAUDE.md` | This file — agent guide |

**Rule:** Models (`ZoteroCollection`, `ZoteroPaper`, `MarginaliaNote`) are
defined ONCE in `BackendService.swift`. Never redefine them in views.

---

## 5. API Contract (keep frontend & backend in lockstep)

If you change a route's shape, update BOTH the Swift Codable model AND the
Python response in the SAME change. The `CodingKeys` map snake_case→camelCase.

```
GET  /collections
     → [{ key, name, paper_count }]

GET  /collections/{id}/papers
GET  /papers
     → [{ key, title, authors, year, abstract, has_pdf }]

GET  /papers/{id}/pdf
     → application/pdf bytes

GET  /papers/{id}/notes
     → [{ id, paper_id, page, content, note_type, thought_type, created_at }]

POST /papers/{id}/notes
     body: { paper_id, page, content, note_type, thought_type? }
     → the created note object

POST /transcribe
     multipart: audio (m4a)
     → { text, language }

── Phase 3: Reflect ────────────────────────────────────────────────────────

GET  /papers/{id}/context
     → { paper_id, reason_saved, reading_goal, created_at, updated_at } | null

PUT  /papers/{id}/context
     body: { reason_saved?, reading_goal? }
     → { paper_id, reason_saved, reading_goal, created_at, updated_at }

GET  /papers/{id}/reflections
     → [{ id, paper_id, source_note_id, reflection_type, prompt, response,
          status, provenance, created_at, answered_at }]

POST /papers/{id}/reflections/generate
     body: { mode: "recall" }
     → [Reflection]   (newly created, status="open")
     503 { code: "model_error" } if Ollama fails or returns invalid JSON

PATCH /papers/{id}/reflections/{reflection_id}
     body: { response?, status? }
     → updated Reflection
```

`note_type` ∈ `"text" | "voice" | "ink"`.
`thought_type` ∈ `"note" | "question" | "connection" | "idea" | "disagreement"` — defaults to `"note"`.
`reflection.status` ∈ `"open" | "answered" | "dismissed"`.
`reflection.provenance` ∈ `"model" | "system"`.

### Schema notes (SQLite migrations — additive only)
- `notes` table got `thought_type TEXT NOT NULL DEFAULT 'note'` added via `ALTER TABLE`.
  Wrapped in `try/except sqlite3.OperationalError` so restarting after migration doesn't fail.
- `paper_context(paper_id PK, reason_saved, reading_goal, created_at, updated_at)` — new table.
- `reflections(id PK, paper_id, source_note_id, reflection_type, prompt, response,
  status, provenance, created_at, answered_at)` — new table.

---

## 6. DESIGN SYSTEM — read carefully

Goal: **clean, modern, calm.** A reading tool, not a dashboard. Lots of
whitespace, restrained color, content-first. Think Things 3 / Bear / Ivory,
not enterprise SaaS. Typography and spacing do the work; color is an accent.

### 6.1 Theming architecture (build this in `Theme.swift`)

NEVER hard-code colors in views. Every color comes from the theme.

```swift
// Theme.swift — structure to implement

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
}

// Swappable accent palettes the user can pick
enum AccentPalette: String, CaseIterable, Identifiable {
    case ink        // default — deep indigo/blue, scholarly
    case forest     // muted green
    case ember      // warm terracotta
    case slate      // near-monochrome, minimal
    case plum       // muted purple
    var id: String { rawValue }
    var accent: Color { ... }       // primary accent
    var accentSoft: Color { ... }   // tinted background for accent
}

final class ThemeManager: ObservableObject {
    @AppStorage("appearance") var appearance: AppAppearance = .system
    @AppStorage("palette")    var palette: AccentPalette = .ink

    // Resolved semantic tokens (see 6.2). These adapt to light/dark.
    // Expose as computed Colors that read the current ColorScheme.
}
```

Inject once in `MarginaliaApp`:
```swift
@StateObject private var theme = ThemeManager()
WindowGroup {
    ContentView()
        .environmentObject(theme)
        .preferredColorScheme(theme.appearance.colorScheme) // nil = system
        .tint(theme.palette.accent)
}
```

### 6.2 Semantic color tokens (use ONLY these in views)

Define each as a function/computed property that resolves for light & dark.
Prefer SwiftUI system materials where possible so dark/light "just works".

| Token | Light | Dark | Use |
|---|---|---|---|
| `bgPrimary` | `#FAFAF8` (warm white) | `#0E0E10` | App background |
| `bgSurface` | `#FFFFFF` | `#1A1A1D` | Cards, sidebars |
| `bgSurfaceAlt` | `#F2F2EF` | `#242428` | Inset fields, hover |
| `textPrimary` | `#1A1A1A` | `#F5F5F3` | Body text |
| `textSecondary`| `#6B6B6B` | `#9A9A9A` | Metadata, captions |
| `textTertiary` | `#A0A0A0` | `#6A6A6A` | Disabled, hints |
| `separator` | `#E5E5E2` | `#2E2E32` | Hairlines |
| `accent` | from palette | from palette | Interactive, selection |
| `accentSoft` | accent @ 12% | accent @ 18% | Selected row bg, badges |
| `highlightYellow` | `#FFE9A8` | `#5C4F1E` | PDF highlight ink |

Notes:
- Warm off-white (`#FAFAF8`) not pure white — easier on eyes for long reading.
- Dark mode is true-ish dark but NOT pure black (`#0E0E10`) to reduce halation.
- All tokens must have a light AND dark value. No exceptions.

### 6.3 Typography

Use system font (SF Pro) with a clear scale. Researchers read a lot — comfort first.

| Style | Size / Weight | Use |
|---|---|---|
| `title` | 22 semibold | Paper titles in detail |
| `headline` | 17 semibold | Section headers, sidebar title |
| `body` | 16 regular | Note content, abstracts |
| `subheadline`| 15 regular | Paper rows |
| `caption` | 13 regular | Metadata, page numbers |
| `caption2` | 11 medium | Tags, badges |

Line spacing on body/notes: generous (`.lineSpacing(4)`).
Handwritten/voice notes may use `.serif` design to feel distinct from UI chrome.

### 6.4 Spacing & shape

- Base unit: 4pt. Use multiples (4, 8, 12, 16, 24, 32).
- Corner radius: 10pt cards, 8pt small elements, 14pt sheets.
- Card padding: 12–16pt. Section gaps: 16–24pt.
- Hairline separators (0.5pt) over heavy dividers.
- Subtle shadows only (or none). Prefer borders/material over drop shadows.

### 6.5 Settings screen (build this)

A `SettingsView` (gear icon in sidebar toolbar, presented as sheet) exposing:
- Appearance: System / Light / Dark (segmented)
- Accent palette: swatches the user taps (live preview)
- Backend URL field (⚙ > Backend), persisted via `@AppStorage("backendURL")`
- (later) Whisper model size

Changes apply instantly via `ThemeManager` (`@AppStorage` persists them).

### 6.6 Component conventions

- Selected list rows: `accentSoft` background, `accent` leading bar or icon.
- Buttons: borderless tinted for primary actions; plain for secondary.
- Empty states: `ContentUnavailableView` with a calm icon + one-line guidance.
- Loading: inline `ProgressView` with short label, never a blocking spinner.
- Floating action buttons in PaperView: circle, `bgSurface` backing at 90%
  opacity, `accent` glyph, soft shadow. Never more than 2 visible at once.

---

## 7. Coding Conventions

### Swift
- async/await only. No completion handlers, no Combine pipelines.
- Networking exclusively through `BackendService` static methods.
- Views are dumb; they call `BackendService` and render. No URLSession in views
  EXCEPT the unavoidable PDF load inside `PDFAnnotationView` (UIViewRepresentable).
- One type per file where reasonable; small helper structs may share a file.
- No force-unwraps on network data. Handle the throw, show a calm error state.
- Use `@EnvironmentObject var theme: ThemeManager` for colors. Read tokens, not
  raw `Color(...)`.
- Keep `ContentView` as the navigation shell only.

### Python
- Keep all routes in `marginalia_backend.py` until it exceeds ~400 lines, then
  split into `routes/` and update this file's File Map.
- Whisper model is lazy-loaded (don't load at import). Keep it that way.
- Never block the event loop with long sync work in async routes unless trivial;
  transcription is acceptable as-is for personal single-user use.
- Validate Zotero/IO errors → raise `HTTPException` with a useful message.

### Cross-cutting
- snake_case in JSON/Python, camelCase in Swift, bridged via `CodingKeys`.
- When adding a field: update Python response, Swift model, AND section 5 here.

---

## 8. Build / Run

**Backend (Mac Mini):**
```bash
pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart
python3 marginalia_backend.py        # serves on 0.0.0.0:8000
# health check:
curl http://localhost:8000/collections
```

**App (MacBook Pro, Xcode):**
1. Info.plist: add `NSMicrophoneUsageDescription`, and ATS
   `NSAllowsArbitraryLoads = YES` (local HTTP over Tailscale).
2. Select the physical iPad as run target, press Run.
3. On first launch, open ⚙ > Backend and paste `http://<mac-mini-tailscale-ip>:8000`
   (run `tailscale ip -4` on the Mac Mini to find it). Takes effect immediately.

---

## 9. Roadmap (do NOT pull future phases forward without being asked)

- **Phase 1 (done):** Zotero library browse → PDF + Pencil → text/voice notes
  persist in SQLite. Theming + light/dark + settings.
- **Phase 2 (done):** Handwriting→text capture of margin ink into searchable notes.
- **Phase 3 (in progress — Reflect milestone):**
  - Reading intention card (reason_saved / reading_goal) — done.
  - thought_type on notes (note/question/connection/idea/disagreement) — done.
  - Reflections persisted in SQLite — done.
  - ReflectView sheet (Recall mode live; Revisit/Resolve/Close reading placeholder) — done.
  - Remaining: note search, spaced resurfacing (scheduled recall), Revisit/Resolve modes.
- **Phase 4:** Concept map / connections across papers (citation graph from
  Semantic Scholar + user-drawn links).

### Reflect design principles (§3 of Phase 3 spec)
- User-authored material is always visually primary.
- Model-generated prompts are visibly labeled ("Suggested by Marginalia") and visually secondary.
- No chat bubbles, no gradients, no excessive icons. Calm, reading-focused.
- The Ollama prompt returns strict JSON only; backend strips markdown fences and validates
  with `json.loads`; returns 503 with `code: "model_error"` if Ollama fails.

When you start a phase, move it into the File Map and API Contract above.

---

## 10. Definition of Done (Phase 1)

- Launch → sidebar lists real Zotero collections with counts.
- Tap collection → real papers; search filters them.
- Tap paper → its actual PDF renders; page number tracks scroll.
- Apple Pencil writes on the PDF smoothly.
- Mic → speak → Whisper text returns → editable → saved → appears in sidebar.
- Notes survive app restart (SQLite).
- Light, dark, and system appearance all look clean; accent palette switch is live.
- No hard-coded colors anywhere in views.
- "Cannot connect" state is calm and offers Retry when the Mac Mini is down.
