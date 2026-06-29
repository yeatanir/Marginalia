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

from fastapi import FastAPI, HTTPException, UploadFile, File, Form
from fastapi.responses import FileResponse
from pydantic import BaseModel
from pyzotero import zotero

# ==================== CONFIGURATION ====================
ZOTERO_LIBRARY_ID   = "YOUR_ZOTERO_USER_ID"
ZOTERO_API_KEY      = "YOUR_ZOTERO_API_KEY"
ZOTERO_LIBRARY_TYPE = "user"

ZOTERO_STORAGE_PATH = Path.home() / "Zotero" / "storage"

WHISPER_MODEL = "large-v3"

DB_PATH      = Path.home() / ".marginalia" / "notes.db"
UPLOADS_PATH = Path.home() / ".marginalia" / "papers"

OLLAMA_BASE  = "http://localhost:11434"
OLLAMA_MODEL = "llama3.2:3b"
# =======================================================

app = FastAPI(title="Marginalia Backend")

# MARK: - Database Setup

def get_db():
    DB_PATH.parent.mkdir(exist_ok=True)
    UPLOADS_PATH.mkdir(exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row

    # Original tables — never modified, only kept
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

    # Additive migration: thought_type on notes
    # Existing rows get DEFAULT 'note'. Wrapped in try/except so restarting the
    # backend after the column already exists does not raise an error.
    try:
        conn.execute(
            "ALTER TABLE notes ADD COLUMN thought_type TEXT NOT NULL DEFAULT 'note'"
        )
    except sqlite3.OperationalError:
        pass  # column already present

    # New tables (Phase 3 — Reflect)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS paper_context (
            paper_id TEXT PRIMARY KEY,
            reason_saved TEXT,
            reading_goal TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS reflections (
            id TEXT PRIMARY KEY,
            paper_id TEXT NOT NULL,
            source_note_id TEXT,
            reflection_type TEXT NOT NULL,
            prompt TEXT NOT NULL,
            response TEXT,
            status TEXT NOT NULL DEFAULT 'open',
            provenance TEXT NOT NULL DEFAULT 'model',
            created_at TEXT NOT NULL,
            answered_at TEXT
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

# MARK: - Pydantic Models

class NoteCreate(BaseModel):
    paper_id: str
    page: int
    content: str
    note_type: str = "text"
    thought_type: str = "note"

class NoteUpdate(BaseModel):
    content: str

class PaperContextUpsert(BaseModel):
    reason_saved: Optional[str] = None
    reading_goal: Optional[str] = None

class ReflectionUpdate(BaseModel):
    response: Optional[str] = None
    status: Optional[str] = None

class GenerateReflectionsRequest(BaseModel):
    mode: str = "recall"

# MARK: - Helper: format a note row as dict

def _note_dict(row) -> dict:
    return {
        "id": row["id"],
        "paper_id": row["paper_id"],
        "page": row["page"],
        "content": row["content"],
        "note_type": row["note_type"],
        "thought_type": row["thought_type"] if "thought_type" in row.keys() else "note",
        "created_at": row["created_at"],
    }

# MARK: - Routes

@app.get("/")
def root():
    return {"status": "Marginalia backend running", "version": "2.0"}

# MARK: Uploaded papers

@app.post("/papers/upload")
async def upload_paper(
    pdf: UploadFile = File(...),
    title: str = Form(default=""),
    authors: str = Form(default=""),
    year: str = Form(default=""),
    abstract: str = Form(default=""),
):
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
            (paper_id, title, authors, year, abstract, filename, created_at),
        )
        db.commit()
    finally:
        db.close()
    return {
        "key": paper_id, "title": title,
        "authors": authors or "Unknown authors", "year": year,
        "abstract": abstract, "has_pdf": True,
    }

@app.get("/papers/uploaded")
def get_uploaded_papers():
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM uploaded_papers ORDER BY created_at DESC"
        ).fetchall()
        return [
            {"key": r["id"], "title": r["title"],
             "authors": r["authors"] or "Unknown authors",
             "year": r["year"], "abstract": r["abstract"], "has_pdf": True}
            for r in rows
        ]
    finally:
        db.close()

@app.delete("/papers/uploaded/{paper_id}")
def delete_uploaded_paper(paper_id: str):
    db = get_db()
    try:
        row = db.execute(
            "SELECT filename FROM uploaded_papers WHERE id = ?", (paper_id,)
        ).fetchone()
        if not row:
            raise HTTPException(404, "Paper not found")
        pdf_path = UPLOADS_PATH / row["filename"]
        if pdf_path.exists():
            pdf_path.unlink()
        db.execute("DELETE FROM uploaded_papers WHERE id = ?", (paper_id,))
        db.execute("DELETE FROM notes WHERE paper_id = ?", (paper_id,))
        db.execute("DELETE FROM paper_context WHERE paper_id = ?", (paper_id,))
        db.execute("DELETE FROM reflections WHERE paper_id = ?", (paper_id,))
        db.commit()
    finally:
        db.close()
    return {"deleted": paper_id}

# MARK: Collections

@app.get("/collections")
def get_collections():
    try:
        zot = get_zotero_client()
        collections = zot.collections()
        result = [
            {"key": c["data"]["key"], "name": c["data"]["name"],
             "paper_count": c["data"].get("numItems", 0)}
            for c in collections
        ]
        return sorted(result, key=lambda x: x["name"])
    except Exception as e:
        raise HTTPException(500, f"Zotero error: {e}")

@app.get("/collections/{collection_id}/papers")
def get_papers_in_collection(collection_id: str):
    try:
        zot = get_zotero_client()
        return _format_papers(zot.collection_items(collection_id))
    except Exception as e:
        raise HTTPException(500, f"Zotero error: {e}")

@app.get("/papers")
def get_all_papers():
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
        if data.get("itemType") not in (
            "journalArticle", "conferencePaper", "preprint", "book", "bookSection"
        ):
            continue
        authors = data.get("creators", [])
        author_str = ", ".join(a.get("lastName", a.get("name", "")) for a in authors[:3])
        if len(authors) > 3:
            author_str += " et al."
        result.append({
            "key": data["key"],
            "title": data.get("title", "Untitled"),
            "authors": author_str or "Unknown authors",
            "year": data.get("date", "")[:4] if data.get("date") else "",
            "abstract": data.get("abstractNote", ""),
            "has_pdf": _find_pdf_for_key(data["key"]) is not None,
        })
    return result

def _find_pdf_for_key(item_key: str) -> Optional[Path]:
    storage = ZOTERO_STORAGE_PATH
    if not storage.exists():
        return None
    key_path = storage / item_key
    if key_path.exists():
        pdfs = [f for f in key_path.iterdir() if f.suffix.lower() == ".pdf"]
        if pdfs:
            return pdfs[0]
    for candidate in storage.rglob("*"):
        if candidate.suffix.lower() == ".pdf" and item_key in candidate.parent.name:
            return candidate
    return None

@app.get("/papers/{paper_id}/pdf")
def get_pdf(paper_id: str):
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
            (c for c in children if c["data"].get("contentType") == "application/pdf"), None
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
    raise HTTPException(404, {
        "code": "pdf_not_found", "paper_id": paper_id,
        "message": f"No PDF found for {paper_id}.",
    })

# MARK: Notes

@app.get("/papers/{paper_id}/notes")
def get_notes(paper_id: str):
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM notes WHERE paper_id = ? ORDER BY created_at DESC",
            (paper_id,),
        ).fetchall()
        return [_note_dict(r) for r in rows]
    finally:
        db.close()

@app.post("/papers/{paper_id}/notes")
def create_note(paper_id: str, note: NoteCreate):
    db = get_db()
    try:
        note_id   = str(uuid.uuid4())
        created_at = datetime.now().isoformat()
        db.execute(
            "INSERT INTO notes (id, paper_id, page, content, note_type, thought_type, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (note_id, paper_id, note.page, note.content, note.note_type, note.thought_type, created_at),
        )
        db.commit()
        return {
            "id": note_id, "paper_id": paper_id,
            "page": note.page, "content": note.content,
            "note_type": note.note_type, "thought_type": note.thought_type,
            "created_at": created_at,
        }
    finally:
        db.close()

@app.delete("/papers/{paper_id}/notes/{note_id}")
def delete_note(paper_id: str, note_id: str):
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

@app.patch("/papers/{paper_id}/notes/{note_id}")
def update_note(paper_id: str, note_id: str, body: NoteUpdate):
    content = body.content.strip()
    if not content:
        raise HTTPException(400, "Content cannot be empty")
    db = get_db()
    try:
        result = db.execute(
            "UPDATE notes SET content = ? WHERE id = ? AND paper_id = ?",
            (content, note_id, paper_id),
        )
        if result.rowcount == 0:
            raise HTTPException(404, "Note not found")
        db.commit()
        row = db.execute("SELECT * FROM notes WHERE id = ?", (note_id,)).fetchone()
        return _note_dict(row)
    finally:
        db.close()

# MARK: Paper context (reading intention)

@app.get("/papers/{paper_id}/context")
def get_paper_context(paper_id: str):
    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM paper_context WHERE paper_id = ?", (paper_id,)
        ).fetchone()
        if not row:
            return None
        return dict(row)
    finally:
        db.close()

@app.put("/papers/{paper_id}/context")
def upsert_paper_context(paper_id: str, body: PaperContextUpsert):
    db = get_db()
    try:
        now = datetime.now().isoformat()
        existing = db.execute(
            "SELECT paper_id FROM paper_context WHERE paper_id = ?", (paper_id,)
        ).fetchone()
        if existing:
            db.execute(
                "UPDATE paper_context SET reason_saved = ?, reading_goal = ?, updated_at = ? "
                "WHERE paper_id = ?",
                (body.reason_saved, body.reading_goal, now, paper_id),
            )
        else:
            db.execute(
                "INSERT INTO paper_context (paper_id, reason_saved, reading_goal, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (paper_id, body.reason_saved, body.reading_goal, now, now),
            )
        db.commit()
        row = db.execute(
            "SELECT * FROM paper_context WHERE paper_id = ?", (paper_id,)
        ).fetchone()
        return dict(row)
    finally:
        db.close()

# MARK: Reflections

@app.get("/papers/{paper_id}/reflections")
def get_reflections(paper_id: str):
    db = get_db()
    try:
        rows = db.execute(
            "SELECT * FROM reflections WHERE paper_id = ? ORDER BY created_at DESC",
            (paper_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        db.close()

@app.post("/papers/{paper_id}/reflections/generate")
def generate_reflections(paper_id: str, body: GenerateReflectionsRequest):
    """Generate persisted reflection prompts from the user's own notes via Ollama."""
    if body.mode != "recall":
        raise HTTPException(400, "Only mode=recall is supported in this version")

    db = get_db()
    try:
        rows = db.execute(
            "SELECT id, content, note_type, thought_type FROM notes "
            "WHERE paper_id = ? ORDER BY created_at DESC LIMIT 30",
            (paper_id,),
        ).fetchall()
    finally:
        db.close()

    if not rows:
        raise HTTPException(404, {
            "code": "no_notes",
            "message": "Write or record a few thoughts first. Reflect uses your notes, not the paper abstract.",
        })

    notes_blob = "\n".join(
        f'[id={r["id"][:8]}, type={r["thought_type"]}] {r["content"]}'
        for r in rows
    )
    system = (
        "You are a reading-recall assistant. Your only purpose is to help the reader "
        "re-engage with their own thinking. You NEVER summarise the paper. "
        "You NEVER add outside facts or interpretations. "
        "You ask questions that require the reader to explain their own reasoning, "
        "uncertainty, interpretation, or connections they noticed. "
        "Avoid trivial wording-completion questions. "
        "You MUST respond with strict JSON and nothing else."
    )
    prompt = (
        f"Here are the reader's notes (id prefix shown for reference):\n\n{notes_blob}\n\n"
        "Generate exactly 2-3 recall prompts grounded only in what the reader wrote.\n"
        "Return ONLY valid JSON in this exact shape:\n"
        '{"reflections": [{"reflection_type": "recall", "prompt": "...", "source_note_id": "...or null"}]}'
    )

    try:
        raw = _ollama(prompt, system)
        # Strip markdown code fences if the model wraps output
        if "```" in raw:
            raw = raw.split("```")[1].lstrip("json").strip()
        data = _json.loads(raw)
        items = data.get("reflections", [])
    except Exception as e:
        raise HTTPException(503, {
            "code": "model_error",
            "message": f"Ollama unavailable or returned invalid JSON: {e}",
        })

    db = get_db()
    try:
        now = datetime.now().isoformat()
        created = []
        for item in items[:3]:
            rid = str(uuid.uuid4())
            prompt_text = str(item.get("prompt", "")).strip()
            source_id   = item.get("source_note_id") or None
            if not prompt_text:
                continue
            db.execute(
                "INSERT INTO reflections "
                "(id, paper_id, source_note_id, reflection_type, prompt, status, provenance, created_at) "
                "VALUES (?, ?, ?, ?, ?, 'open', 'model', ?)",
                (rid, paper_id, source_id, "recall", prompt_text, now),
            )
            created.append({
                "id": rid, "paper_id": paper_id,
                "source_note_id": source_id, "reflection_type": "recall",
                "prompt": prompt_text, "response": None,
                "status": "open", "provenance": "model",
                "created_at": now, "answered_at": None,
            })
        db.commit()
        return created
    finally:
        db.close()

@app.patch("/papers/{paper_id}/reflections/{reflection_id}")
def update_reflection(paper_id: str, reflection_id: str, body: ReflectionUpdate):
    db = get_db()
    try:
        row = db.execute(
            "SELECT * FROM reflections WHERE id = ? AND paper_id = ?",
            (reflection_id, paper_id),
        ).fetchone()
        if not row:
            raise HTTPException(404, "Reflection not found")

        new_response = body.response if body.response is not None else row["response"]
        new_status   = body.status   if body.status   is not None else row["status"]
        answered_at  = row["answered_at"]

        if body.status == "answered" and not row["answered_at"]:
            answered_at = datetime.now().isoformat()

        db.execute(
            "UPDATE reflections SET response = ?, status = ?, answered_at = ? "
            "WHERE id = ?",
            (new_response, new_status, answered_at, reflection_id),
        )
        db.commit()
        row = db.execute(
            "SELECT * FROM reflections WHERE id = ?", (reflection_id,)
        ).fetchone()
        return dict(row)
    finally:
        db.close()

# MARK: Transcription

@app.post("/transcribe")
async def transcribe_audio(audio: UploadFile = File(...)):
    try:
        audio_data = await audio.read()
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".m4a")
        tmp.write(audio_data)
        tmp.close()
        whisper = get_whisper()
        segments, info = whisper.transcribe(
            tmp.name, language="en", beam_size=5, vad_filter=True
        )
        text = " ".join(segment.text.strip() for segment in segments)
        os.unlink(tmp.name)
        return {"text": text, "language": info.language}
    except Exception as e:
        raise HTTPException(500, f"Transcription error: {e}")

# MARK: Ollama helpers

import urllib.request as _urlreq
import json as _json

def _ollama(prompt: str, system: str = "") -> str:
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

# MARK: Legacy route (kept for one version — use /reflections/generate instead)

@app.post("/papers/{paper_id}/questions")
def generate_questions_legacy(paper_id: str):
    """Deprecated — use POST /papers/{paper_id}/reflections/generate instead."""
    db = get_db()
    try:
        rows = db.execute(
            "SELECT content, note_type FROM notes WHERE paper_id = ? ORDER BY created_at DESC LIMIT 30",
            (paper_id,),
        ).fetchall()
    finally:
        db.close()
    if not rows:
        raise HTTPException(404, {"code": "no_notes", "message": "Write some notes first."})
    notes_blob = "\n".join(f"[{r['note_type']}] {r['content']}" for r in rows)
    system = (
        "You are a study-recall assistant. You ONLY ask questions about what the user "
        "explicitly wrote in their notes. You NEVER summarise the paper or add outside knowledge."
    )
    prompt = (
        f"Here are the user's notes:\n\n{notes_blob}\n\n"
        "Generate exactly 2-3 short recall questions (one per line, no numbering, no preamble). Nothing else."
    )
    try:
        response = _ollama(prompt, system)
        questions = [q.strip() for q in response.splitlines() if q.strip()][:3]
        return {"questions": questions, "paper_id": paper_id}
    except Exception as e:
        raise HTTPException(503, f"Ollama unavailable: {e}")

# MARK: Run

if __name__ == "__main__":
    import uvicorn
    print("Starting Marginalia backend...")
    print(f"Notes database: {DB_PATH}")
    print(f"Zotero storage: {ZOTERO_STORAGE_PATH}")
    print(f"Ollama model:   {OLLAMA_MODEL} at {OLLAMA_BASE}")
    uvicorn.run(app, host="0.0.0.0", port=8000)
