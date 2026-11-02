# Jot

Private notes with a floating panel on the Mac (⌥N) and a native Android app, synced through **your own server**,
**end-to-end encrypted**: the server only ever stores ciphertext.

- Markdown with live preview (symbols hide while you write): headings, bold/italic/strike/underline, lists,
  checkboxes, quotes, code blocks with syntax colours, links, images and videos
- `[[links]]` between notes, backlinks, `#tags`, full-text search, related notes, and a graph of your notes
- Several Mac windows, each with its own note; they come back after a restart
- Apps update themselves from your server; no app store, no third-party services

| Folder | What |
|---|---|
| `server/` | Sync server: one file, plain Node, no dependencies (`server.js`) + Docker Compose file |
| `spec/` | Reference implementation of the crypto, note logic and sync rules (JS); both apps are tested against its fixtures |
| `mac/` | Mac app (Swift, AppKit + SwiftUI). Built from source on the Mac by `install.sh` |
| `android/` | Android app (Kotlin, Jetpack Compose). Built in Docker by `build.sh` |

## How the encryption works
A random 256-bit data key encrypts every note and file on the device (AES-256-GCM). The server keeps that key only
*wrapped* with a key derived from your passphrase (PBKDF2), plus a hash to check the passphrase. **If you lose the
passphrase, your notes can't be recovered.**

The server is **single-user**: the first device that connects sets the passphrase and claims it. So run it where
only you can reach it (a VPN such as Tailscale or WireGuard, or an IP allow-list), behind HTTPS.

## 1. Run the server
```sh
cd server
mkdir -p data public && sudo chown 1000:1000 data     # the container runs as uid 1000 ("node")
docker compose up -d                                   # listens on 127.0.0.1:8080
```
Put an HTTPS reverse proxy in front of it, e.g. Caddy:
```
notes.example.com {
    reverse_proxy 127.0.0.1:8080
}
```
Back up `server/data/` (it's encrypted, but it's all your notes).

## 2. Mac app (macOS 13+)
On the machine that holds the server folder:
```sh
cd mac
echo https://notes.example.com > origin.txt     # your server
./publish.sh                                    # copies the source to server/public/mac/
```
Then on the Mac (needs Apple's Command Line Tools; the script offers to install them):
```sh
curl -fsSL https://notes.example.com/mac/install.sh | bash
```
Jot builds itself, starts at login, lives in the menu bar (✎) and opens with ⌥N. Every later `./publish.sh` is
picked up by the Mac app on its own (menu-bar icon → Update Automatically).

## 3. Android app (Android 8+)
Needs Docker (the Android SDK lives only in the build image):
```sh
cd android
echo https://notes.example.com > origin.txt
./build.sh "first version"       # tests + signed APK → dist/jot.apk, also copied to server/public/android/
```
Open `https://notes.example.com/android/jot.apk` on the phone once; later builds install with one tap from inside
the app. The first run of `build.sh` creates your signing key in `android/keys/`: **back it up and never publish
it**. Without it, phones can't update the app in place.

If you're publishing your own fork, change the app IDs: `app.jot` (Android, `android/app/build.gradle.kts`) and
`app.jot.mac` (Mac, `mac/install.sh`).

## Tests
```sh
node server/test/server.test.mjs   # server + two reference clients
mac/test/run.sh                    # Swift core vs. spec fixtures + live sync against the Node server (Docker)
android/build.sh test              # Kotlin vs. spec fixtures + fake-server sync (Docker)
```
To change a crypto, logic or sync rule: change `spec/*.mjs` first, run `node spec/fixtures.mjs`, then mirror it in
`mac/Sources/JotCore.swift` and `android/app/src/main/kotlin/app/jot/` (Logic.kt / Repo.kt / Crypto.kt).

## Credits
Code colouring: [highlight.js](https://highlightjs.org) (BSD-3, `mac/Resources/highlight.LICENSE`).
Android font: [Inter](https://rsms.me/inter/) (SIL OFL 1.1, `android/INTER-LICENSE.txt`).

## License
MIT, see `LICENSE`.
