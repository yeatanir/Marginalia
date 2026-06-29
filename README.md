<p align="center">
  <img src="icon.png" alt="Marginalia" width="160" style="border-radius:22%" />
</p>

<p align="center">
  <strong>Marginalia</strong><br/>
  <em>Your understanding, preserved.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iPadOS_18+-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/backend-Python_FastAPI-green?style=flat-square" />
  <img src="https://img.shields.io/badge/transcription-Whisper_large--v3-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" />
  <img src="https://img.shields.io/badge/cost-completely_free-brightgreen?style=flat-square" />
</p>

---

## The problem

There is a particular kind of loss that happens silently, paper by paper, across a research career.

You read something carefully. Something clicks — a connection to a method you tried six months ago, a question the authors didn't ask, a suspicion that their parameterisation won't hold at high temperatures. You underline a sentence. Maybe you scribble something in the margin. Then you close the PDF and move on.

Three weeks later, you remember that you had a thought. You cannot remember what it was. The underline is there. The margin note is illegible, or gone entirely, or trapped inside a PDF on a device you no longer use.

The thought — yours, original, the product of your specific expertise reading this specific paper — is gone.

This is not a minor inconvenience. **It is the slow erosion of the thing that makes a researcher irreplaceable:** the accumulated, connected, personal understanding that cannot be reconstructed by any language model, because it was never written down anywhere a language model could reach.

---

## What Marginalia does

An iPad app for reading research papers the way researchers actually read them: pen in hand, writing in the margins.

- **Apple Pencil on the PDF.** Circle, underline, write in your own handwriting. Strokes are anchored to each page and survive scroll and zoom.
- **Voice notes while you read.** Tap mic, speak, stop. Whisper large-v3 transcribes your thought — tuned for accented English and scientific vocabulary — on your own hardware.
- **Ink → searchable text.** One tap converts your handwritten strokes to a text note using Apple's on-device Vision ML. Runs entirely on the iPad, no network needed.
- **Notes that stay.** Everything lands in SQLite, attached to the page it came from, persistent across app restarts.
- **Tag your thinking.** Mark notes as Note, Question, Connection, Idea, or Disagreement when you capture them.
- **Reflect.** Come back to what you wrote and re-engage with your own thinking — four modes, no AI required for three of them.

---

## What it is not

- Not a summariser. AI summaries replace thinking. Marginalia captures it.
- Not a cloud service. Everything runs on hardware you own.
- Not a subscription. Free forever.
- Not another Zotero. It works *with* your Zotero library.

---

## How it works

```
Your iPad                     Your always-on Mac (Mac Mini or MacBook)
─────────────────────         ────────────────────────────────────────
PDF viewer (PDFKit)           FastAPI backend  :8000
Apple Pencil → ink            Zotero API  →  your library metadata
Handwriting → text  ◄───►    ~/Zotero/storage  →  PDF files
Voice → audio                 Whisper large-v3  →  transcription
Notes sidebar                 SQLite  →  your notes
                              (Phase 3) Ollama + Gemma/Llama  →  interrogation
```

All communication over Tailscale (or your local network). No cloud. No third-party servers.

---

## Setup options

You have three ways to run the backend, from simplest to most powerful. **Pick the one that matches what you have.**

---

### Option A — Your main Mac (simplest, fully free)

If you only have one Mac, run the backend on it. The limitation is that the backend only works when your Mac is awake — fine if you read papers at your desk.

```bash
# 1. Clone
git clone https://github.com/yeatanir/Marginalia.git
cd Marginalia

# 2. Install backend dependencies
pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart

# 3. Configure credentials (see "Zotero credentials" below)
cp Marginalia/marginalia_backend.example.py Marginalia/marginalia_backend.py
# Edit marginalia_backend.py and fill in ZOTERO_LIBRARY_ID, ZOTERO_API_KEY

# 4. Run
python3 Marginalia/marginalia_backend.py
```

Your Mac's local IP (e.g. `192.168.1.x`) works fine when the iPad and Mac are on the same Wi-Fi. For use away from home, add both to [Tailscale](https://tailscale.com) (free) and use the Tailscale IP instead.

---

### Option B — Always-on server (recommended for researchers)

This is how the original author uses it. An always-on Mac Mini (or any always-on machine — an old MacBook left plugged in works too) runs the backend 24/7 and the iPad can reach it from anywhere via Tailscale.

```bash
# On the server Mac:
git clone https://github.com/yeatanir/Marginalia.git
pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart
cp Marginalia/marginalia_backend.example.py Marginalia/marginalia_backend.py
# Edit credentials, then:
python3 Marginalia/marginalia_backend.py
```

**PDF sync with Syncthing (free, unlimited):**
If Zotero desktop runs on your MacBook, its PDFs live there, not on the server. [Syncthing](https://syncthing.net) mirrors them over:
1. MacBook: share `~/Zotero/storage` as **Send Only**
2. Server Mac: accept the share as **Receive Only**

No size limit, no subscription, runs over Tailscale automatically.

> **Without Syncthing:** the backend falls back to fetching PDFs from the Zotero web API. This works but has a 300 MB free storage cap.

**Auto-start on boot:**
```bash
# Replace YOUR_USERNAME and path as needed
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

---

### Option C — API key for transcription (no local model needed)

If you don't want to run Whisper locally (it downloads a ~3 GB model on first use), you can swap in an API-based transcription service. The backend is structured so this is a small edit to `marginalia_backend.py`.

**Groq (free tier, very fast — recommended):**
```python
# pip3 install groq
from groq import Groq
client = Groq(api_key="gsk_...")  # free at console.groq.com

@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    audio_bytes = await audio.read()
    result = client.audio.transcriptions.create(
        model="whisper-large-v3",
        file=("recording.m4a", audio_bytes, "audio/m4a"),
    )
    return {"text": result.text, "language": "en"}
```

**OpenAI Whisper API (~$0.006/minute):**
```python
# pip3 install openai
import openai
client = openai.OpenAI(api_key="sk-...")

@app.post("/transcribe")
async def transcribe(audio: UploadFile = File(...)):
    audio_bytes = await audio.read()
    transcript = client.audio.transcriptions.create(
        model="whisper-1",
        file=("recording.m4a", audio_bytes, "audio/m4a"),
    )
    return {"text": transcript.text, "language": "en"}
```

The iPad app is unchanged — it talks to the same `/transcribe` endpoint regardless of what's behind it.

---

### What if I don't use Zotero?

You can use Marginalia without Zotero by uploading PDFs directly from the app (tap **+** in the collections view). Uploaded papers are stored on the backend and annotated identically to Zotero papers.

Alternatively, fork the backend and point `ZOTERO_STORAGE_PATH` at any folder of PDFs — the Zotero metadata API is only used for the collections sidebar; PDF serving and notes work on any files.

---

## Zotero credentials

1. Go to [zotero.org/settings/keys](https://www.zotero.org/settings/keys)
2. Note your **numeric User ID** (shown under your username on that page)
3. Click **Create new private key** → read-only library access → save
4. Fill in `marginalia_backend.py`:

```python
ZOTERO_LIBRARY_ID   = "12345678"          # numeric, not your username
ZOTERO_API_KEY      = "aBcDeFgHiJkLmN..."
ZOTERO_STORAGE_PATH = Path("/Users/YOUR_USERNAME/Zotero/storage")
```

---

## Building the iPad app

**Requirements:** Mac with Xcode 16+, iPad with iPadOS 18+, Apple Pencil, free Apple ID.

```
1. Open Marginalia.xcodeproj in Xcode
2. Signing & Capabilities → Team: sign in with your Apple ID → personal team
3. Change Bundle Identifier to something unique (e.g. com.yourname.marginalia)
4. Connect iPad via USB, select it as the target
5. Press ▶
```

**Set your backend URL** — after first launch, tap ⚙ in the app → Backend → paste your Mac's IP and port (`http://192.168.x.x:8000` on local Wi-Fi, or the Tailscale IP for remote access). This setting persists across app updates.

**Enable Developer Mode on iPad** (required once): Settings → Privacy & Security → Developer Mode → on → restart.

**Trust the certificate** (first time only): Settings → General → VPN & Device Management → your Apple ID → Trust.

> With a **free Apple ID**, the app certificate expires every 7 days. Rebuild from Xcode to renew (~30 seconds, all data intact). With a **paid Apple Developer account** ($99/year), certificates last 1 year.

---

## On-device ML — features that work offline

Several features run entirely on the iPad with no backend:

| Feature | Technology | Needs backend? |
|---|---|---|
| Ink → text note | Apple Vision (VNRecognizeTextRequest) | No |
| PDF rendering | Apple PDFKit | No |
| Drawing / annotation | Apple PencilKit | No |

For a **fully offline setup**, you can replace Whisper transcription with Apple's `SFSpeechRecognizer` (on-device, supports many languages, no download). Quality is lower than Whisper large-v3 for accented English and scientific vocabulary, but it works with no Mac at all. This is left as a fork-friendly customisation point in the transcription route.

---

## Reflect

After you've taken notes on a paper, tap **Reflect** in the notes sidebar. A sheet opens with four modes:

### Recall
The only mode that uses AI. Sends your notes to a small local model (Ollama on your Mac) and gets back questions that ask *you* to explain your own thinking — not the paper's content. One prompt at a time. You write or speak a response. Responses are saved to SQLite and persist across app restarts. Prompts are visibly labeled "Suggested by Marginalia" so model output is never presented as your own thought.

### Revisit
No AI. Shows your notes in the order you wrote them — oldest first. For each note: did you still think the same thing by the end? Write or speak a follow-up. It saves as a "connection" note on the same page.

### Resolve
No AI. Filters only notes you tagged as **Question** or **Disagreement**. For each: did you find an answer? Did your view change? Write or speak a resolution. Saves as a new note on the same page.

### Close reading
No AI. Pick a page from the page bar at the top. All your annotations for that page are shown. Write or speak a synthesis: in your own words, what was the argument or finding here? Saves as a note.

**Voice input is available in every response field** — tap the mic icon next to "Your response," speak, tap stop. Whisper transcribes it and appends it to the text. Same model as the voice note recorder.

---

## Ollama / local LLM (Reflect — Recall mode)

The Recall mode in Reflect generates recall prompts from *your own notes* using a small local LLM via Ollama.

```bash
# On the server Mac
brew install ollama
ollama serve          # starts on localhost:11434

# Pick a model based on your RAM
ollama pull gemma3:4b        # 4B params, ~3 GB — fast, great for Q&A (author's choice)
ollama pull llama3.2:3b      # 3B params, ~2 GB — very fast
ollama pull gemma3:12b       # 12B params, ~8 GB — higher quality
```

Set `OLLAMA_MODEL` in `marginalia_backend.py` to match the model you pulled. The author uses **Gemma 3 4B** — it handles "generate 3 recall questions from these research notes" reliably on Apple Silicon without a dedicated GPU.

---

## Whisper model sizes

The author uses `large-v3` for best accuracy with accented English and scientific terms. Smaller models work if RAM is a constraint:

| Model | Download | Speed | Notes |
|---|---|---|---|
| `tiny` | ~75 MB | Very fast | Clear speech, quiet environment |
| `base` | ~150 MB | Fast | Good for standard accents |
| `small` | ~500 MB | Fast | Most accents, general use |
| `medium` | ~1.5 GB | Moderate | Strong accents, technical vocab |
| `large-v3` | ~3 GB | Slower | Best overall — recommended |

Change `WHISPER_MODEL` in `marginalia_backend.py` to switch.

---

## Tailscale setup (for remote access)

Tailscale creates a private network between your devices so the iPad reaches the Mac backend from anywhere without opening ports or configuring a router.

1. Install Tailscale on the Mac: [tailscale.com/download](https://tailscale.com/download)
2. Install Tailscale on the iPad: [App Store](https://apps.apple.com/app/tailscale/id1470499037)
3. Log in with the same account on both
4. `tailscale ip -4` on the Mac gives you the Tailscale IP — use this in the app's Backend setting

Tailscale's free tier covers up to 3 devices (iPad + server Mac + MacBook).

---

## Troubleshooting

**"Cannot connect" on iPad**
Both devices must be on Tailscale or the same Wi-Fi. Test: `curl http://<your-mac-ip>:8000/` should return `{"status":"ok"}`.

**Voice transcription times out on first use**
Whisper large-v3 (~3 GB) downloads on the first request. Monitor: `tail -f /tmp/marginalia.log` on the backend Mac.

**PDFs not loading**
Check `ZOTERO_STORAGE_PATH`. If Syncthing hasn't synced yet, enable Zotero file sync as a temporary fallback.

**Reflect → Recall fails to generate prompts**
Ollama must be running (`ollama serve`) and the model must be pulled (`ollama pull gemma3:4b`). Ensure `OLLAMA_MODEL` in `marginalia_backend.py` matches exactly. Revisit, Resolve, and Close reading don't use Ollama and work offline.

**App stops launching after ~7 days (free Apple ID)**
Normal behaviour. Plug iPad into Mac, open Xcode, press ▶. ~30 seconds, all data intact.

---

## Contributing

Issues and PRs welcome. Read `CLAUDE.md` before contributing — it has the full architecture, design system, and coding conventions.

---

## Acknowledgements

- [Zotero](https://www.zotero.org) — the reference manager that respects researchers
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) — Whisper inference that runs on real hardware
- [Tailscale](https://tailscale.com) — making "your own server" actually work
- [Ollama](https://ollama.com) — local LLMs without a PhD in DevOps
- The generation effect (Slamecka & Graf, 1978) — the cognitive science this is built on

---

## Built with Claude

This project was designed and built with the help of [Claude](https://claude.ai) (Anthropic). The architecture, Swift app, Python backend, and design system were developed collaboratively through Claude Code.

---

<p align="center"><em>"What you understand by yourself is yours."</em></p>
