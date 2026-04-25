# Markzzy — Tests

Two test targets, two scopes.

## `MarkzzyTests` — unit tests (CI-safe)

Fast, deterministic, no hardware. Run on every PR via `.github/workflows/ci.yml`.

### Files

| File | Tests | Coverage |
|---|---|---|
| `DeviceFilterTests.swift` | iPhoneAffinity scoring across 4 signals (Continuity, modelID, manufacturer, name), tiebreakers, virtual-camera filter | `DeviceFilter` 100% |
| `CameraBridgeDetectorTests.swift` | Detection by device name, by DAL plugin, multi-bridge, unknown camera handling | `CameraBridgeDetector` 100% |
| `PIPCompositorTests.swift` | All shape variants compose without crashes, output dimensions match base | `PIPCompositor` |
| `LibraryTests.swift` | Video listing, deletion, sort order | `LibraryStore` |

### Running

```bash
swift test --filter MarkzzyTests
```

### Adding new unit tests

When testing AVFoundation-related code:

1. **Don't instantiate `AVCaptureDevice`** — it requires actual hardware and CI doesn't have iPhones.
2. **Use pure-data overloads** — see `DeviceFilter.iPhoneAffinity(deviceType:modelID:manufacturer:localizedName:)` for the pattern. Public API takes `AVCaptureDevice`, internal overload takes primitives. Test the primitive version.
3. **Use temp directories for filesystem-backed detection** — see `CameraBridgeDetectorTests.makeTempDALWith(filenames:)`.

## `MarkzzyE2ETests` — integration tests (local only)

These need actual hardware (camera, mic, screen recording permissions, optionally a real iPhone for Continuity). They are **NOT run in CI** because GitHub runners can't grant TCC permissions interactively.

### Files

| File | What it tests |
|---|---|
| `RecordingPipelineE2ETests.swift` | Full record → encode → write → read-back cycle |

### Running locally

```bash
swift test --filter MarkzzyE2ETests
```

The first run will trigger TCC prompts for camera, mic, and screen recording. Grant them all.

### When to run

Before tagging a release. Manual smoke check.

## Stress / race-condition scripts

Standalone Swift scripts in `scripts/` exercise specific bugs we've fixed:

- `scripts/test-wake-race.swift` — proves the AVCaptureSession threading bug (mutating from main + background = SIGABRT) and that our serial-queue fix resolves it. Runs 50 cycles in both modes.

  ```bash
  xcrun swift scripts/test-wake-race.swift broken      # expect crash
  xcrun swift scripts/test-wake-race.swift serialized  # expect PASS
  ```

## Coverage targets

| Module | Target | Current |
|---|---|---|
| `DeviceFilter` | 100% | ✅ 100% |
| `CameraBridgeDetector` | 100% | ✅ 100% |
| `PIPCompositor` | ≥80% | (existing) |
| `CameraCoordinator` (post-Sprint-3 refactor) | ≥80% | TBD |
| `AppModel` (orchestration only) | ≥60% | TBD |
| `Permissions` | covered by E2E | (E2E) |

## What we DON'T test

- AVFoundation itself (Apple's responsibility).
- The Sparkle framework (third-party).
- TCC behavior (system-level, not deterministic in tests).
- Real Continuity Camera handshake (depends on physical iPhone presence).
- Real bridge software interaction (Camo, EpocCam, etc. — would require their licenses and installations on CI).

For these, we rely on:
- Swift's type system catching API misuse at compile time.
- Manual smoke tests before each release.
- Diagnostic UI (`Settings → Detected cameras`) for support tickets.
