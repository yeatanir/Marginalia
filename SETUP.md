# Marginalia — Setup Guide

Full technical instructions for getting Marginalia running on your own hardware.

---

## Requirements

| Component | Requirement |
|---|---|
| iPad | iPadOS 18+, Apple Pencil |
| Build machine | Mac with Xcode 16+ |
| Backend | Any Mac you own (always-on recommended) |
| Apple ID | Free is fine (see note on certificates below) |

---

## 1. Backend

### Install dependencies

```bash
pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart
```

### Configure credentials

```bash
cp Marginalia/marginalia_backend.example.py Marginalia/marginalia_backend.py
```

Edit `marginalia_backend.py` and fill in:

```python
ZOTERO_LIBRARY_ID   = "12345678"          # numeric user ID (not your username)
ZOTERO_API_KEY      = "aBcDeFgHiJkLmN..."
ZOTERO_STORAGE_PATH = Path("/Users/YOUR_USERNAME/Zotero/storage")
```

Get your Zotero credentials at [zotero.org/settings/keys](https://www.zotero.org/settings/keys). Your numeric User ID appears under your username. Create a new private key with read-only library access.

### Run

```bash
python3 Marginalia/marginalia_backend.py
# Health check:
curl http://localhost:8000/
```

---

## 2. Backend options

### Option A — Your main Mac (simplest)

Run the backend on whichever Mac you have. Works fine for reading at your desk. The backend is only reachable when the Mac is awake.

Use your Mac's local IP (`192.168.x.x`) on the same Wi-Fi, or a Tailscale IP for remote access.

### Option B — Always-on server (recommended)

An always-on Mac Mini (or any Mac left plugged in) runs the backend 24/7. The iPad reaches it from anywhere via Tailscale.

**PDF sync with Syncthing (free, unlimited):**
If Zotero desktop runs on your MacBook, its PDFs live there. [Syncthing](https://syncthing.net) mirrors them to the server:
1. MacBook: share `~/Zotero/storage` as **Send Only**
2. Server: accept as **Receive Only**

> Without Syncthing, the backend falls back to fetching PDFs from the Zotero web API (300 MB free cap).

**Auto-start on boot:**

```bash
cat > ~/Library/LaunchAgents/com.marginalia.backend.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.marginalia.backend</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/YOUR_USERNAME/Marginalia/Marginalia/marginalia_backend.py</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/marginalia.log</string>
    <key>StandardErrorPath</key><string>/tmp/marginalia.err</string>
</dict>
</plist>
EOF
launchctl load ~/Library/LaunchAgents/com.marginalia.backend.plist
```

### Option C — API-based transcription (no local Whisper)

If you don't want the ~3 GB Whisper model locally, swap in an API. The backend is structured so this is a small edit to the `/transcribe` route.

**Groq (free tier, very fast):**
```python
# pip3 install groq
from groq import Groq
client = Groq(api_key="gsk_...")  # free at console.groq.com

@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    result = client.audio.transcriptions.create(
        model="whisper-large-v3",
        file=("recording.m4a", await audio.read(), "audio/m4a"),
    )
    return {"text": result.text, "language": "en"}
```

**OpenAI (~$0.006/min):**
```python
# pip3 install openai
import openai
client = openai.OpenAI(api_key="sk-...")

@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    transcript = client.audio.transcriptions.create(
        model="whisper-1",
        file=("recording.m4a", await audio.read(), "audio/m4a"),
    )
    return {"text": transcript.text, "language": "en"}
```

---

## 3. Building the iPad app

1. Open `Marginalia.xcodeproj` in Xcode
2. Signing & Capabilities → Team → sign in with your Apple ID → personal team
3. Change Bundle Identifier to something unique (e.g. `com.yourname.marginalia`)
4. Connect iPad via USB, select it as the run target
5. Press ▶

**Enable Developer Mode on iPad** (once): Settings → Privacy & Security → Developer Mode → on → restart.

**Trust the certificate** (first time): Settings → General → VPN & Device Management → your Apple ID → Trust.

**Set your backend URL**: tap ⚙ in the app → Backend → paste `http://<your-mac-ip>:8000`. This setting persists and takes effect immediately — no recompile needed.

> **Free Apple ID**: the certificate expires every 7 days. Plug into Mac, open Xcode, press ▶ — ~30 seconds, all data intact. With a paid Apple Developer account ($99/year), certificates last 1 year.

---

## 4. Tailscale (remote access)

Tailscale creates a private network between your devices so the iPad can reach the backend from anywhere, without port forwarding.

1. Install on the Mac: [tailscale.com/download](https://tailscale.com/download)
2. Install on the iPad: [App Store](https://apps.apple.com/app/tailscale/id1470499037)
3. Sign in with the same account on both
4. Run `tailscale ip -4` on the Mac to get its Tailscale IP
5. Enter that IP in the app's Backend setting

Free tier covers up to 3 devices (iPad + server + MacBook).

---

## 5. Ollama — local LLM for Reflect (Recall mode)

Reflect's Recall mode uses a small local LLM to generate prompts from your own notes.

```bash
# On the backend Mac
brew install ollama
ollama serve          # starts on localhost:11434

# Pull a model (choose based on available RAM)
ollama pull gemma3:4b        # ~3 GB — fast, recommended
ollama pull llama3.2:3b      # ~2 GB — very fast
ollama pull gemma3:12b       # ~8 GB — higher quality
```

Set `OLLAMA_MODEL` in `marginalia_backend.py` to match the model you pulled. The Revisit, Resolve, and Close reading modes in Reflect do not use Ollama and work with no model running.

---

## 6. Whisper model sizes

Change `WHISPER_MODEL` in `marginalia_backend.py` to switch. The model downloads on first use.

| Model | Download | Speed | Best for |
|---|---|---|---|
| `tiny` | ~75 MB | Very fast | Clear speech, quiet environments |
| `base` | ~150 MB | Fast | Standard accents |
| `small` | ~500 MB | Fast | Most accents, general use |
| `medium` | ~1.5 GB | Moderate | Strong accents, technical vocab |
| `large-v3` | ~3 GB | Slower | Best overall — recommended |

---

## 7. On-device features (no backend needed)

| Feature | Technology |
|---|---|
| PDF rendering | Apple PDFKit |
| Drawing / annotation | Apple PencilKit |
| Ink → text note | Apple Vision (VNRecognizeTextRequest) |

For a fully offline setup, `SFSpeechRecognizer` can replace Whisper for voice input — it runs on-device, supports many languages, and needs no Mac at all. Quality is lower for accented English and technical vocabulary. This is left as a fork-friendly customisation point in the `/transcribe` route.

---

## 8. Without Zotero

You can use Marginalia without Zotero by uploading PDFs directly from the app (tap **+** next to "My PDFs" in the sidebar). Uploaded papers are stored on the backend and annotated identically to Zotero papers, including full Reflect support.

To point the backend at an arbitrary folder of PDFs, set `ZOTERO_STORAGE_PATH` in `marginalia_backend.py` to that folder. The Zotero metadata API is only used for the collections sidebar.

---

## 9. Troubleshooting

**"Cannot connect" on iPad**
Both devices must be on Tailscale or the same Wi-Fi. Test from a terminal: `curl http://<your-mac-ip>:8000/` should return `{"status":"Marginalia backend running"}`.

**Voice transcription times out on first use**
Whisper large-v3 (~3 GB) downloads on the first transcription request. Watch progress: `tail -f /tmp/marginalia.log` on the backend Mac.

**PDFs not loading**
Check `ZOTERO_STORAGE_PATH` in `marginalia_backend.py`. If Syncthing hasn't synced yet, enable Zotero file sync as a temporary fallback (300 MB free cap).

**Uploaded PDFs not appearing after refresh**
Pull down on the sidebar (pull-to-refresh) or tap the ↺ button in the top right. Both reload collections and uploaded papers together.

**Reflect → Recall fails to generate prompts**
Ollama must be running (`ollama serve`) and the model must be pulled (`ollama pull gemma3:4b`). Check that `OLLAMA_MODEL` in `marginalia_backend.py` matches the pulled model exactly. Revisit, Resolve, and Close reading work without Ollama.

**Reading intention won't save**
The backend must be running and reachable. Test with `curl http://<mac-ip>:8000/`. Check `/tmp/marginalia.log` on the backend Mac for errors.

**App stops launching after ~7 days**
Expected with a free Apple ID. Plug the iPad into the Mac, open Xcode, press ▶. Takes ~30 seconds and all notes are preserved.
