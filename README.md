<p align="center">
  <img src="assets/marginalia-wordmark.png" alt="Marginalia" width="280" />
</p>

<p align="center">
  <em>Your understanding, preserved.</em>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iPadOS_26.5-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/backend-Python_FastAPI-green?style=flat-square" />
  <img src="https://img.shields.io/badge/transcription-Whisper_large--v3-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square" />
  <img src="https://img.shields.io/badge/cost-completely_free-brightgreen?style=flat-square" />
</p>

---

## The problem

There is a particular kind of loss that happens silently, paper by paper, across a research career.

You read something carefully. Something clicks — a connection to a method you tried six months ago, a question the authors didn't ask, a suspicion that their parameterization won't hold at high temperatures. You underline a sentence. Maybe you scribble something in the margin. Then you close the PDF and move on.

Three weeks later, you remember that you had a thought. You cannot remember what it was. You re-read the paper. The underline is there. The margin note is illegible, or gone entirely, or trapped inside a PDF on a device you no longer use.

The thought — yours, original, the product of your specific expertise reading this specific paper — is gone.

This is not a minor inconvenience. **It is the slow erosion of the thing that makes a researcher irreplaceable:** the accumulated, connected, personal understanding that cannot be reconstructed by any language model, because it was never written down anywhere a language model could reach.

---

## What AI got wrong

The response to information overload in research has been more AI: more summarization, more automatic extraction, more feeds of "relevant" papers, more bullet points that tell you what a paper says so you don't have to read it yourself.

This is exactly backwards.

A summary tells you what someone else decided was important. It does not tell you what *you* would have noticed, what connections *you* would have made, what questions *your* specific research context would have raised. Reading a summary and feeling like you understood a paper is the illusion of understanding — and it is arguably worse than not reading the paper at all, because it closes off the question without opening the thinking.

The generation effect — documented in cognitive science since 1978 — is unambiguous: **information you generate yourself is retained dramatically better than information you receive passively.** Your confused margin question encodes better than a clean AI summary. Your voice note, rambling and uncertain, is worth more than a five-bullet abstract.

Marginalia is built on this premise. The AI in this tool does not think for you. It helps you think better, and it makes sure the thinking you already did doesn't disappear.

---

## What Marginalia is

An iPad app for reading research papers the way researchers actually read them: pen in hand, writing in the margins.

**Apple Pencil on the PDF.** Circle a word. Underline a claim you're skeptical of. Write a question in the margin in your own handwriting. The app captures it — handwriting converted to searchable text on-device, privately, by Apple's own ML — and attaches it to that exact page of that exact paper.

**Voice notes while you read.** Tap the mic and speak. Not a dictated summary — a live thought. "This is the same problem Erhart was trying to solve in 2005, but they've gone around it differently and I'm not sure it holds for the oxidation case." Whisper large-v3 handles the transcription, tuned for accented English and scientific vocabulary, running entirely on your own hardware.

**Notes that stay.** Everything lands in one place, attached to its source, searchable, retrievable. Not lost in a PDF. Not forgotten in a folder. Yours.

**Your understanding, resurfaces.** Later — days or weeks after you annotated a paper — the app brings back what *you* wrote and asks if you still believe it. Not a quiz generated from the abstract. A question generated from your own words. The difference matters enormously.

---

## What Marginalia is not

- Not a paper discovery tool. Finding papers is a solved problem.
- Not a summarizer. AI summaries replace thinking. Marginalia captures it.
- Not a cloud service. Everything runs on your own hardware.
- Not a subscription. Completely free, now and always.
- Not another Zotero. It works *with* your existing Zotero library.

---

## The philosophy in one sentence

> Use AI to restore the conditions under which deep thinking was possible — not to replace the thinking itself.

---

## How it works

```
Your iPad                     Your Mac Mini (always-on)
─────────────────────         ──────────────────────────────────
PDF viewer                    FastAPI backend
Apple Pencil → ink            Zotero API → your library metadata
Handwriting → text            ~/Zotero/storage → your PDFs
                     ◄───►    Whisper large-v3 → transcription
Voice → audio                 SQLite → your notes
Notes sidebar                 (later) Ollama → interrogation engine
```

All communication over Tailscale. No cloud. No third-party servers. No data leaves your machines.

Your MacBook Pro runs Xcode and builds the app. Your Mac Mini runs the backend and stays on. Your iPad is where you actually read.

---

## Roadmap

### Phase 1 — Capture ← current
The foundation. PDF + Pencil + voice. Notes persist and are retrievable. Your thinking stops evaporating.

### Phase 2 — Search
Handwriting-to-text across all papers. Global note search. Find the thought you had three months ago.

### Phase 3 — Interrogation
The spaced retrieval engine. Not generated from abstracts — generated from your own notes. The AI asks you to defend what *you* wrote, not summarize what the authors said.

### Phase 4 — Connection
Concept maps across papers. Citation graph integration. See how the thing you read last week connects to the thing you read in your first year.

---

## Setup

This is a personal tool you build and run yourself. There is no App Store listing. You sideload the app onto your own iPad from Xcode, and you run the backend on a Mac you own.

### What you need

| Component | What for | Cost |
|---|---|---|
| iPad with Apple Pencil | Running the app | — (you have one) |
| Always-on Mac (Mac Mini, MacBook left on, etc.) | Backend server | — |
| Mac with Xcode | Building and signing the app | — |
| Apple ID (free) | Signing the app | Free — no payment needed |
| [Tailscale](https://tailscale.com) | Private network between all devices | Free |
| [Zotero](https://www.zotero.org) | Your reference library | Free |
| Python 3.10+ | Running the backend | — |

> **You do not need to pay anything.** A free Apple ID is all that's required to build and run this on your own iPad. The only catch is that Xcode's free signing certificate expires every 7 days — after which the app stops launching until you hit ▶ in Xcode again (takes ~30 seconds, your data is untouched). The $99/year Apple Developer Program is only needed if you want to distribute to other people's devices or publish to the App Store.

---

### Step 1 — Clone the repo

```bash
git clone https://github.com/yeatanir/Marginalia.git
cd Marginalia
```

---

### Step 2 — Mac Mini: configure and run the backend

Install dependencies:

```bash
pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart
```

Get your Zotero credentials at [zotero.org/settings/keys](https://www.zotero.org/settings/keys):
- Note your numeric **User ID** (shown under your username)
- Create a new **private key** with read-only library access

Copy the example config and fill in your credentials:

```bash
cp Marginalia/marginalia_backend.example.py Marginalia/marginalia_backend.py
```

Open `marginalia_backend.py` and edit the configuration block at the top:

```python
ZOTERO_LIBRARY_ID   = "12345678"           # your numeric user ID
ZOTERO_API_KEY      = "aBcDeFgHiJkLmN..."  # your API key
ZOTERO_STORAGE_PATH = Path("/Users/YOUR_USERNAME/Zotero/storage")
WHISPER_MODEL       = "large-v3"            # best for accented English + science
```

Run it:

```bash
python3 Marginalia/marginalia_backend.py
```

Test: open `http://localhost:8000/collections` — you should see your Zotero collections as JSON.

Find your Mac Mini's Tailscale IP (you'll need it for the app):

```bash
tailscale ip -4
```

---

### Step 3 — PDF sync with Syncthing

Your Zotero desktop app runs on your MacBook, so your PDFs live there. The backend on the Mac Mini needs to read them without you having to pay for Zotero storage.

Install [Syncthing](https://syncthing.net) on both machines (free, open-source, peer-to-peer):

1. On MacBook: add `~/Zotero/storage` as a shared folder, set to **Send Only**
2. On Mac Mini: accept the share, set to **Receive Only**, path `~/Zotero/storage`
3. Syncthing runs over your existing Tailscale connection automatically

Once set up, the Mac Mini has a live read-only mirror of all your PDFs. No size limit, no subscription.

> If you skip Syncthing for now, the backend falls back to fetching PDFs from the Zotero web API (works but has a 300 MB free storage cap).

---

### Step 4 — Build and sideload the iPad app

**Open the project in Xcode:**

```
Open Marginalia.xcodeproj in Xcode
```

**Set your signing team:**

1. Click the `Marginalia` project in the navigator
2. Select the `Marginalia` target → **Signing & Capabilities**
3. Under **Team**, sign in with your Apple ID and select your personal team
4. Change **Bundle Identifier** to something unique, e.g. `com.yourname.marginalia`

Xcode will automatically manage your signing certificate.

**Set your backend URL:**

Open `Marginalia/BackendService.swift` and update the default URL:

```swift
static let defaultBaseURL = "http://100.x.x.x:8000"  // your Mac Mini's Tailscale IP
```

Alternatively, leave the default and set it at runtime: after first launch, tap ⚙ → Backend and paste the URL there. This is persistent and survives app updates.

**Enable Developer Mode on your iPad** (required for sideloaded apps):

Settings → Privacy & Security → Developer Mode → turn on, restart when prompted.

**Connect your iPad via USB, select it as the target in Xcode, press ▶.**

The first build takes a minute. After that, if Xcode and the iPad are on the same network, subsequent builds are wireless.

**Trust the certificate on iPad** (first time only):

Settings → General → VPN & Device Management → your Apple ID → Trust.

> With a free Apple Developer account, you'll need to rebuild and reinstall from Xcode every 7 days. With a paid account ($99/year), certificates last 1 year.

---

### Step 5 — Make the backend start automatically on the Mac Mini

```bash
# Replace YOUR_USERNAME with your Mac Mini username
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

Check that it started: `curl http://localhost:8000/`

---

### Step 6 — Connect iPad to Tailscale

Install [Tailscale](https://apps.apple.com/app/tailscale/id1470499037) on your iPad and log in with the same account used on the Mac Mini. The iPad can then reach the backend at its Tailscale IP even when you're away from home.

---

## Using the app

**PKToolPicker (pen palette):** The floating palette appears automatically when you open a paper. Switch between pen, pencil, marker, and eraser from there. It stays docked at the bottom or side of the screen.

**Drawing:** Apple Pencil draws. Finger scrolls and pinch-zooms. Both work simultaneously.

**Ink → text note:** After writing on a page, tap the **⊕ viewfinder** icon in the top toolbar. Apple's on-device ML (Vision framework) reads your handwriting and saves it as a searchable text note attached to that page. Runs entirely on the iPad, no network needed.

**Clear ink:** Tap the **trash** icon in the top toolbar to clear all strokes on the current page.

**Voice note:** Tap the mic FAB (floating button, bottom right). Speak. Stop. Whisper transcribes it on your Mac Mini — tuned for accented English and scientific vocabulary. Review and edit the text, then save.

**Quiz me:** After writing notes on a paper, open the notes sidebar (notebook icon, bottom right) and tap "Quiz me." Ollama generates 2-3 recall questions from *your own notes*, not the abstract. Requires Ollama running on the Mac Mini.

---

## Troubleshooting

**"Cannot connect" on iPad**
Both devices must be connected to Tailscale. Check the backend IP in Settings → Backend. Verify the backend is running: `curl http://<mac-mini-tailscale-ip>:8000/`.

**Voice transcription times out on first use**
Whisper large-v3 (~3GB) downloads on the first transcription request. Wait 5-10 minutes on a good connection. Subsequent calls are fast. You can watch the download: `tail -f /tmp/marginalia.log` on the Mac Mini.

**PDFs not loading**
Check `ZOTERO_STORAGE_PATH` in your `marginalia_backend.py`. If Syncthing hasn't synced yet, enable Zotero file sync temporarily — the backend falls back to the web API. Check logs: `tail -f /tmp/marginalia.log`.

**"Quiz me" fails**
Ollama must be running on the Mac Mini: `ollama serve`. Pull a model if you haven't: `ollama pull llama3.2:3b`. Set `OLLAMA_MODEL` accordingly in `marginalia_backend.py`.

**Handwriting recognition (ink → text) returns nothing**
Make sure you have actual ink strokes on the current page before tapping the viewfinder icon. The recognition runs on-device and requires a somewhat legible script. Block letters work better than cursive for short tests.

**App stops launching after ~7 days**
This is normal with a free Apple ID. Plug in your iPad (or be on the same WiFi), open Xcode, press ▶. Takes ~30 seconds. All your notes and drawings are stored locally and survive the rebuild completely intact.

---

## Contributing

Marginalia is open source and will stay that way. If you're a researcher who reads papers with a pen in hand and has lost more thoughts than you can count, this was built for you.

Issues and PRs welcome. Read `CLAUDE.md` before contributing — it has the full architecture, design system, and coding conventions.

---

## Acknowledgements

Built on the shoulders of:
- [Zotero](https://www.zotero.org) — the reference manager that actually respects researchers
- [faster-whisper](https://github.com/guillaumekynast/faster-whisper) — Whisper inference that runs on real hardware
- [Tailscale](https://tailscale.com) — making "your own server" actually work
- The generation effect (Slamecka & Graf, 1978) — the cognitive science this tool is built on
- Every researcher who ever filled a book's margins with better thoughts than the book itself

---

<p align="center">
  <em>"What you understand by yourself is yours."</em>
</p>
