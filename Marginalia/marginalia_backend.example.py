"""
Marginalia Backend — runs on your Mac Mini

Setup:
    pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart
    cp marginalia_backend.example.py marginalia_backend.py
    # Fill in your Zotero credentials below, then:
    python3 marginalia_backend.py

Runs on 0.0.0.0:8000. Your iPad connects to this over Tailscale.
"""

import os
import uuid
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, UploadFile, File
from fastapi.responses import FileResponse
from pydantic import BaseModel
from pyzotero import zotero

# ==================== CONFIGURATION ====================
# Get from https://www.zotero.org/settings/keys
ZOTERO_LIBRARY_ID = "YOUR_ZOTERO_USER_ID"   # numeric ID (e.g. "12345678")
ZOTERO_API_KEY    = "YOUR_ZOTERO_API_KEY"    # read-only key from same page
ZOTERO_LIBRARY_TYPE = "user"  # or "group"

# Where Zotero stores PDFs locally on your Mac Mini
# Usually: /Users/yourname/Zotero/storage
ZOTERO_STORAGE_PATH = Path.home() / "Zotero" / "storage"

# Whisper model: tiny / base / medium / large-v3
# For Indian-accented English + scientific terms: large-v3 recommended
WHISPER_MODEL = "large-v3"

# Where to store Marginalia notes database and uploaded PDFs
DB_PATH = Path.home() / ".marginalia" / "notes.db"
UPLOADS_PATH = Path.home() / ".marginalia" / "papers"

# Ollama — local AI for note-based recall questions (Phase 3)
# Run: ollama serve   Pull a model: ollama pull llama3.2:3b
OLLAMA_BASE   = "http://localhost:11434"
OLLAMA_MODEL  = "llama3.2:3b"   # or gemma4:12b if you have the RAM
# =======================================================

app = FastAPI(title="Marginalia Backend")

# MARK: - Database Setup

def get_db():
    DB_PATH.parent.mkdir(exist_ok=True)
    UPLOADS_PATH.mkdir(exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("""
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY,
            paper_id TEXT NOT NULL,
            page INTEGER NOT NULL,
            content TEXT NOT NULL,
            note_type TEXT NOT NULL DEFAULT 'text',
            created_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS uploaded_papers (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            authors TEXT NOT NULL DEFAULT '',
            year TEXT NOT NULL DEFAULT '',
            abstract TEXT NOT NULL DEFAULT '',
            filename TEXT NOT NULL,
            created_at TEXT NOT NULL
        )
    """)
    conn.commit()
    return conn

# MARK: - Zotero Client

def get_zotero_client():
    return zotero.Zotero(ZOTERO_LIBRARY_ID, ZOTERO_LIBRARY_TYPE, ZOTERO_API_KEY)

# MARK: - Whisper (lazy loaded)

_whisper_model = None

def get_whisper():
    global _whisper_model
    if _whisper_model is None:
        print(f"Loading Whisper {WHISPER_MODEL}... (first run only)")
        from faster_whisper import WhisperModel
        _whisper_model = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
        print("Whisper ready.")
    return _whisper_model

# MARK: - Models

class NoteCreate(BaseModel):
    paper_id: str
    page: int
    content: str
    note_type: str = "text"

# MARK: - Routes

@app.get("/")
def root():
    return {"status": "Marginalia backend running", "version": "1.0"}

# MARK: Uploaded papers (user-uploaded PDFs, not from Zotero)

@app.post("/papers/upload")
async def upload_paper(
    pdf: UploadFile = File(...),
    title: str = "",
    authors: str = "",
    year: str = "",
    abstract: str = "",
):
    """Upload a PDF directly. Stored in ~/.marginalia/papers/ and tracked in SQLite."""
    if not title:
        title = Path(pdf.filename or "Untitled").stem

    pdf_data = await pdf.read()
    paper_id = str(uuid.uuid4())
    filename = f"{paper_id}.pdf"
    pdf_path = UPLOADS_PATH / filename
    UPLOADS_PATH.mkdir(parents=True, exist_ok=True)
    pdf_path.write_bytes(pdf_data)

    db = get_db()
    try:
        created_at = datetime.now().isoformat()
        db.execute(
            "INSERT INTO uploaded_papers (id, title, authors, year, abstract, filename, created_at) VALUES (?,?,?,?,?,?,?)",
            (paper_id, title, authors, year, abstract, filename, created_at)
        )
        db.commit()
    finally:
        db.close()

    print(f"[upload] saved {filename} — '{title}'")
    return {
        "key": paper_id,
        "title": title,
        "authors": authors or "Unknown authors",
        "year": year,
        "abstract": abstract,
        "has_pdf": True,
    }

@app.get("/papers/uploaded")
def get_uploaded_papers():
    """Return all user-uploaded papers."""
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM uploaded_papers ORDER BY created_at DESC"
        ).fetchall()
        return [
            {
                "key": row["id"],
                "title": row["title"],
                "authors": row["authors"] or "Unknown authors",
                "year": row["year"],
                "abstract": row["abstract"],
                "has_pdf": True,
            }
            for row in rows
        ]
    finally:
        db.close()

@app.delete("/papers/uploaded/{paper_id}")
def delete_uploaded_paper(paper_id: str):
    """Delete an uploaded paper and its PDF file."""
    db = get_db()
    try:
        row = db.execute(
            "SELECT filename FROM uploaded_papers WHERE id = ?", (paper_id,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Paper not found")
        pdf_path = UPLOADS_PATH / row["filename"]
        if pdf_path.exists():
            pdf_path.unlink()
        db.execute("DELETE FROM uploaded_papers WHERE id = ?", (paper_id,))
        db.execute("DELETE FROM notes WHERE paper_id = ?", (paper_id,))
        db.commit()
    finally:
        db.close()
    return {"deleted": paper_id}

@app.get("/collections")
def get_collections():
    """Return all Zotero collections with paper counts."""
    try:
        zot = get_zotero_client()
        collections = zot.collections()
        result = []
        for col in collections:
            data = col["data"]
            result.append({
                "key": data["key"],
                "name": data["name"],
                "paper_count": data.get("numItems", 0)
            })
        return sorted(result, key=lambda x: x["name"])
    except Exception as e:
        raise HTTPException(500, f"Zotero error: {e}")

@app.get("/collections/{collection_id}/papers")
def get_papers_in_collection(collection_id: str):
    """Return all papers in a given collection."""
    try:
        zot = get_zotero_client()
        items = zot.collection_items(collection_id)
        return _format_papers(items)
    except Exception as e:
        raise HTTPException(500, f"Zotero error: {e}")

@app.get("/papers")
def get_all_papers():
    """Return all papers in the library."""
    try:
        zot = get_zotero_client()
        items = zot.items(itemType="journalArticle || conferencePaper || preprint || book")
        return _format_papers(items)
    except Exception as e:
        raise HTTPException(500, f"Zotero error: {e}")

def _format_papers(items):
    result = []
    for item in items:
        data = item.get("data", {})
        if data.get("itemType") not in ("journalArticle", "conferencePaper", "preprint", "book", "bookSection"):
            continue

        authors = data.get("creators", [])
        author_str = ", ".join(
            a.get("lastName", a.get("name", "")) for a in authors[:3]
        )
        if len(authors) > 3:
            author_str += " et al."

        has_pdf = _find_pdf_for_key(data["key"]) is not None

        result.append({
            "key": data["key"],
            "title": data.get("title", "Untitled"),
            "authors": author_str or "Unknown authors",
            "year": data.get("date", "")[:4] if data.get("date") else "",
            "abstract": data.get("abstractNote", ""),
            "has_pdf": has_pdf
        })
    return result

def _find_pdf_for_key(item_key: str) -> Optional[Path]:
    """Find PDF file in local Zotero storage for a given item key."""
    storage = ZOTERO_STORAGE_PATH
    if not storage.exists():
        print(f"[pdf] storage path missing: {storage}")
        return None

    key_path = storage / item_key
    if key_path.exists():
        pdfs = [f for f in key_path.iterdir() if f.suffix.lower() == ".pdf"]
        if pdfs:
            print(f"[pdf] found (direct): {pdfs[0]}")
            return pdfs[0]
        print(f"[pdf] folder exists but no PDF inside: {key_path}")

    for candidate in storage.rglob("*"):
        if candidate.suffix.lower() == ".pdf" and item_key in candidate.parent.name:
            print(f"[pdf] found (rglob): {candidate}")
            return candidate

    print(f"[pdf] not found in local storage for key: {item_key}")
    return None

@app.get("/papers/{paper_id}/pdf")
def get_pdf(paper_id: str):
    """Serve the PDF for a paper. 200 = raw bytes; 404 = structured JSON."""
    print(f"[pdf] request for {paper_id}")

    uploaded_path = UPLOADS_PATH / f"{paper_id}.pdf"
    if uploaded_path.exists():
        return FileResponse(str(uploaded_path), media_type="application/pdf")

    pdf_path = _find_pdf_for_key(paper_id)
    if pdf_path and pdf_path.exists():
        return FileResponse(str(pdf_path), media_type="application/pdf")

    try:
        zot = get_zotero_client()
        children = zot.children(paper_id)
        pdf_child = next(
            (c for c in children if c["data"].get("contentType") == "application/pdf"),
            None
        )
        if pdf_child:
            attachment_key = pdf_child["data"]["key"]
            local_path = _find_pdf_for_key(attachment_key)
            if local_path and local_path.exists():
                return FileResponse(str(local_path), media_type="application/pdf")

            try:
                pdf_data = zot.file(attachment_key)
                tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".pdf")
                tmp.write(pdf_data)
                tmp.close()
                return FileResponse(tmp.name, media_type="application/pdf")
            except Exception as e:
                print(f"[pdf] Zotero cloud download failed: {e}")
    except Exception as e:
        print(f"[pdf] failed to resolve via Zotero API: {e}")

    raise HTTPException(
        status_code=404,
        detail={
            "code": "pdf_not_found",
            "paper_id": paper_id,
            "message": (
                f"No PDF found for {paper_id}. "
                "Ensure the file has synced to ~/Zotero/storage on the Mac Mini "
                "via Syncthing, or enable Zotero file sync for the web API fallback."
            ),
        }
    )

@app.get("/papers/{paper_id}/notes")
def get_notes(paper_id: str):
    """Return all notes for a paper."""
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM notes WHERE paper_id = ? ORDER BY created_at DESC",
            (paper_id,)
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        db.close()

@app.post("/papers/{paper_id}/notes")
def create_note(paper_id: str, note: NoteCreate):
    """Save a new note for a paper."""
    db = get_db()
    try:
        note_id = str(uuid.uuid4())
        created_at = datetime.now().isoformat()
        db.execute(
            "INSERT INTO notes (id, paper_id, page, content, note_type, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            (note_id, paper_id, note.page, note.content, note.note_type, created_at)
        )
        db.commit()
        return {
            "id": note_id,
            "paper_id": paper_id,
            "page": note.page,
            "content": note.content,
            "note_type": note.note_type,
            "created_at": created_at
        }
    finally:
        db.close()

@app.delete("/papers/{paper_id}/notes/{note_id}")
def delete_note(paper_id: str, note_id: str):
    """Delete a single note."""
    db = get_db()
    try:
        result = db.execute(
            "DELETE FROM notes WHERE id = ? AND paper_id = ?", (note_id, paper_id)
        )
        if result.rowcount == 0:
            raise HTTPException(404, "Note not found")
        db.commit()
    finally:
        db.close()
    return {"deleted": note_id}

class NoteUpdate(BaseModel):
    content: str

@app.patch("/papers/{paper_id}/notes/{note_id}")
def update_note(paper_id: str, note_id: str, body: NoteUpdate):
    """Edit the text content of a note (e.g. fix Whisper or ink-recognition errors)."""
    content = body.content.strip()
    if not content:
        raise HTTPException(400, "Content cannot be empty")
    db = get_db()
    try:
        result = db.execute(
            "UPDATE notes SET content = ? WHERE id = ? AND paper_id = ?",
            (content, note_id, paper_id)
        )
        if result.rowcount == 0:
            raise HTTPException(404, "Note not found")
        db.commit()
        row = db.execute("SELECT * FROM notes WHERE id = ?", (note_id,)).fetchone()
        return dict(row)
    finally:
        db.close()

@app.post("/transcribe")
async def transcribe_audio(audio: UploadFile = File(...)):
    """Transcribe audio using Whisper — handles accented English well."""
    try:
        audio_data = await audio.read()
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".m4a")
        tmp.write(audio_data)
        tmp.close()

        whisper = get_whisper()
        segments, info = whisper.transcribe(
            tmp.name,
            language="en",
            beam_size=5,
            vad_filter=True
        )

        text = " ".join(segment.text.strip() for segment in segments)
        os.unlink(tmp.name)

        return {"text": text, "language": info.language}
    except Exception as e:
        raise HTTPException(500, f"Transcription error: {e}")

# MARK: - Ollama helpers

import urllib.request as _urlreq
import json as _json

def _ollama(prompt: str, system: str = "") -> str:
    """Call Ollama and return the response text. Raises on failure."""
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    payload = _json.dumps({
        "model": OLLAMA_MODEL,
        "messages": messages,
        "stream": False,
    }).encode()
    req = _urlreq.Request(
        f"{OLLAMA_BASE}/api/chat",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    with _urlreq.urlopen(req, timeout=120) as resp:
        return _json.loads(resp.read())["message"]["content"].strip()

# MARK: - Phase 3 routes

@app.post("/papers/{paper_id}/questions")
def generate_questions(paper_id: str):
    """Generate 2-3 recall questions grounded strictly in the user's own notes."""
    db = get_db()
    try:
        rows = db.execute(
            "SELECT content, note_type FROM notes WHERE paper_id = ? ORDER BY created_at DESC LIMIT 30",
            (paper_id,)
        ).fetchall()
    finally:
        db.close()

    if not rows:
        raise HTTPException(404, detail={"code": "no_notes", "message": "Write some notes first — questions are generated from your own annotations."})

    notes_blob = "\n".join(f"[{r['note_type']}] {r['content']}" for r in rows)
    system = (
        "You are a study-recall assistant. You ONLY ask questions about what the user "
        "explicitly wrote in their notes. You NEVER summarise the paper or add outside knowledge."
    )
    prompt = (
        f"Here are the user's notes:\n\n{notes_blob}\n\n"
        "Generate exactly 2-3 short recall questions (one per line, no numbering, no preamble) "
        "that test whether the user remembers what they wrote. Nothing else."
    )
    try:
        response = _ollama(prompt, system)
        questions = [q.strip() for q in response.splitlines() if q.strip()][:3]
        return {"questions": questions, "paper_id": paper_id}
    except Exception as e:
        raise HTTPException(503, detail=f"Ollama unavailable: {e}")

@app.get("/papers/{paper_id}/note_tags")
def tag_notes(paper_id: str):
    """Use Ollama to group the user's notes into topic clusters/labels."""
    db = get_db()
    try:
        rows = db.execute(
            "SELECT id, content FROM notes WHERE paper_id = ? ORDER BY created_at DESC",
            (paper_id,)
        ).fetchall()
    finally:
        db.close()

    if not rows:
        return {"tags": {}}

    notes_blob = "\n".join(f"[{r['id'][:8]}] {r['content']}" for r in rows)
    prompt = (
        f"Notes:\n{notes_blob}\n\n"
        "Group these notes by topic. Return JSON only: "
        "{\"tags\": {\"<label>\": [\"<note_id_prefix>\", ...]}}. "
        "Use 2-4 short topic labels. No explanation."
    )
    try:
        raw = _ollama(prompt)
        if "```" in raw:
            raw = raw.split("```")[1].lstrip("json").strip()
        data = _json.loads(raw)
        return data
    except Exception as e:
        raise HTTPException(503, detail=f"Ollama unavailable or bad response: {e}")

# MARK: - Run

if __name__ == "__main__":
    import uvicorn
    print("Starting Marginalia backend...")
    print(f"Notes database: {DB_PATH}")
    print(f"Zotero storage: {ZOTERO_STORAGE_PATH}")
    print(f"Ollama model: {OLLAMA_MODEL} at {OLLAMA_BASE}")
    uvicorn.run(app, host="0.0.0.0", port=8000)
