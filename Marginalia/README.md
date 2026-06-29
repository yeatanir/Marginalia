# Marginalia — Setup Guide

## What this is
An iPad app for reading research papers with Apple Pencil + voice notes.
Your Mac Mini is the backend. Your MacBook Pro runs Xcode.

---

## Step 1 — Mac Mini Backend Setup

### Install dependencies
```bash
pip3 install fastapi uvicorn pyzotero faster-whisper python-multipart
```

### Get your Zotero credentials
1. Go to https://www.zotero.org/settings/keys
2. Click "Create new private key"
3. Give it read-only access to your library
4. Copy your User ID (shown on that same page) and the API key

### Edit marginalia_backend.py
Open the file and fill in at the top:
```python
ZOTERO_LIBRARY_ID = "12345678"          # your numeric user ID
ZOTERO_API_KEY    = "aBcDeFgHiJkL..."   # your API key
ZOTERO_STORAGE_PATH = Path("/Users/YOUR_USERNAME/Zotero/storage")
```

### Run the backend
```bash
python3 marginalia_backend.py
```

Test it works: open http://localhost:8000/collections in your browser.
You should see your Zotero collections as JSON.

### Find your Tailscale IP
```bash
tailscale ip -4
```
This gives you something like 100.x.x.x — you need this for the iPad app.

---

## Step 2 — iPad App Setup (Xcode on MacBook Pro)

### Add the Swift files
In Xcode, right-click the Marginalia folder → New File → Swift File for each:
- BackendService.swift
- PaperListView.swift  
- PaperView.swift

Replace ContentView.swift and MarginaliaApp.swift with the provided code.

### Set your Mac Mini's Tailscale IP
Open BackendService.swift and replace:
```swift
static let baseURL = "http://YOUR-MAC-MINI-TAILSCALE-IP:8000"
```
with your actual Tailscale IP:
```swift
static let baseURL = "http://100.x.x.x:8000"
```

### Add required permissions
In Xcode, click your project → Marginalia target → Info tab.
Add these keys:
- Privacy - Microphone Usage Description → "Record voice notes for papers"
- App Transport Security Settings → Allow Arbitrary Loads → YES (needed for local HTTP)

### Connect your iPad
Plug iPad into MacBook via USB → trust the connection.
In Xcode top bar, change target from simulator to your iPad.
Hit the Play button (▶).

---

## Step 3 — Make backend run automatically on Mac Mini

```bash
# Create a simple launch agent so it starts on boot
cat > ~/Library/LaunchAgents/com.marginalia.backend.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.marginalia.backend</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/YOUR_USERNAME/Marginalia/marginalia_backend.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/marginalia.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/marginalia.err</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.marginalia.backend.plist
```

---

## How to use it

1. Open Marginalia on your iPad (backend must be running on Mac Mini)
2. Tap a collection → tap a paper → PDF opens
3. **Write with Apple Pencil** directly on the PDF — circles, underlines, margin notes
4. Tap the **mic button** → speak your thought → Whisper transcribes it → review → save
5. Tap the **notes button** to open the sidebar and see all your notes for this paper

---

## Troubleshooting

**"Cannot connect" error on iPad**
- Make sure backend is running: `python3 marginalia_backend.py` on Mac Mini
- Make sure both iPad and MacBook are on Tailscale
- Check the Tailscale IP is correct in BackendService.swift

**Voice transcription fails**
- Whisper downloads the model on first run (~3GB for large-v3) — wait for it
- Check Mac Mini has internet access for first download

**PDFs not loading**
- Check ZOTERO_STORAGE_PATH points to the right folder on Mac Mini
- Papers added via browser extension should be there automatically
