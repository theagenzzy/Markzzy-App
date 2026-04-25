# Markzzy — Security Notes

This document describes Markzzy's threat model, the mitigations in place,
and the trade-offs we explicitly chose.

## Threat model

Markzzy is a desktop screen + camera + microphone recorder that runs locally
on a user's Mac, distributed as a self-signed `.app` bundle (not via the
App Store) with optional Sparkle-based auto-updates.

The realistic attackers are:

1. **Malicious update channel** — attacker compromises our update feed and
   pushes a backdoored binary.
2. **Local malicious software** — another app on the user's Mac tries to
   piggyback on Markzzy's TCC permissions or capture frames in flight.
3. **Process injection** — attacker injects a dylib at launch to alter
   recording behavior or exfiltrate data.
4. **User input** — paths, license codes, URL handler tokens. All bounded.

We are **not** in scope for:

- Nation-state attackers with kernel access.
- Physical attackers with the user's unlocked Mac.
- Attacks that require the user to disable SIP or Gatekeeper.

## Mitigations in place

### 1. Code signing
- Production builds are signed with a Developer ID certificate
  (`.github/workflows/release.yml`).
- Local dev builds use a stable self-signed identity (`Markzzy Self Sign`)
  so TCC permissions persist across rebuilds (`scripts/setup-signing.sh`).
- All builds use **Hardened Runtime** (`--options=runtime`) which:
  - Blocks dylib injection from unsigned libraries.
  - Prevents arbitrary processes from claiming our entitlements.
  - Disables `dlopen` of unsigned binaries.

### 2. Entitlements (minimal)
- `com.apple.security.device.camera` — required, prompts user via TCC.
- `com.apple.security.device.audio-input` — required, prompts user via TCC.
- `com.apple.security.cs.disable-library-validation` — required for Sparkle
  to load its differently-signed `Updater.app` child. **Single relaxation**
  on Hardened Runtime; everything else stays hardened.
- We deliberately do NOT enable `com.apple.security.app-sandbox` because the
  sandbox would break per-device TCC for cameras / mics. Distribution is
  outside the App Store.

### 3. Update channel hardening
- Feed URL is **HTTPS only**: `https://markzzy.tech/api/releases/appcast.xml`.
- Updates are **EdDSA-signed**. The public key (`SUPublicEDKey`) is baked
  into the production Info.plist. Sparkle refuses to install any update
  whose signature doesn't verify.
- Local dev builds set `SUEnableAutomaticChecks=false` and ship without
  `SUPublicEDKey` — Sparkle silently disables updates entirely on local
  builds, preventing any feed fetch or attempted install.
- `SUEnableJavaScript` is **never set** (would allow JS in release notes).

### 4. No data exfiltration
- Captured frames live only in-process (`CIImage` → `CVPixelBuffer` →
  `AVAssetWriter`). Never sent over the network.
- The output file lives only at the user-chosen `outputDirectory`
  (default `~/Desktop/Videos`), with a timestamped filename Markzzy
  generates — no user-controlled string in the path. No traversal vector.
- License-related network calls (`api.markzzy.tech`) only ever transmit
  the user's email + license token — never device IDs, recordings, or
  capture content.
- **Zero `print` / `NSLog` / `os_log` calls in production source.** No
  pixel data, no PII, no tokens are ever logged.

### 5. Capture session lifecycle
- `previewSession` only runs while the user has the Record tab active and
  a camera selected.
- The recording pipeline only writes to disk after the user explicitly
  presses "Start Recording" (with optional 3-2-1 countdown).
- macOS shows the green camera indicator dot whenever the session is
  active — the user always knows.
- When the user quits Markzzy, all sessions tear down via Cocoa's normal
  termination path.

### 6. Camera-bridge defense (Camo, EpocCam, Iriun, …)
- We use a layered scoring system (`DeviceFilter.iPhoneAffinity`) to bind
  to the **real iPhone** rather than a third-party bridge's virtual camera,
  even when bridges are installed.
- Signals in decreasing trust:
  - Score 4 — `.continuityCamera` device type (Apple's native path).
  - Score 3 — `modelID` starts with `iPhone*` (only real iPhones report this).
  - Score 3 — `manufacturer` is "Apple" + non-built-in (resilience signal
    for bridges that strip modelID but can't fake manufacturer).
  - Score 2 — name contains `iphone` (last-resort name match).
  - Score 1 — generic bridge driver name (Camo Camera, EpocCam HD, …) —
    only bound when user opts into virtual cameras via Settings.
- This means a malicious bridge that fakes a Camo Camera entry but exposes
  no real iPhone cannot trick us into binding to it.

### 7. Process privilege
- Markzzy never escalates privilege. No `sudo`, no XPC helper, no
  privileged tasks. The setup script (`scripts/setup-signing.sh`) does
  use `security` to manage the user's keychain, but that's user-level
  and only run by the developer, never by an end user.

## Explicitly chosen trade-offs

These are things we could mitigate but actively choose not to:

- **App-sandbox**: would break per-device TCC. Required for App Store but
  we distribute directly. Cost > benefit for our threat model.
- **Cert pinning for license API**: HTTPS + the system cert chain is
  enough. Cert pinning adds maintenance burden (rotate certs in app
  releases) without meaningful gain against our threat model.
- **Anti-tampering / anti-debug**: we are too small a target for binary
  patching attacks. The cost is high and the benefit is theatre.
- **Stop preview when window not key**: the green camera indicator already
  informs the user. Stopping & restarting the session adds 100-300 ms of
  perceived lag every time they tab back. Not worth it.
- **Telemetry**: we collect zero telemetry. If we add it later, it will be
  opt-in with explicit explanation of what's sent.

## Reporting issues

If you find a security issue in Markzzy, please email security@markzzy.tech
(if that exists) or open a private security advisory on GitHub. Do not
disclose publicly until we've had a reasonable chance to ship a fix.
