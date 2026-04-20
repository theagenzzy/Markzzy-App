# Markzzy

Markzzy graba pantalla y cara a la vez en macOS. Tu iPhone aparece como cámara vía Continuity Camera — sin app móvil, sin pairing.

## Requisitos
- macOS 13 Ventura o superior
- Swift 5.9+ (incluido con Xcode o Command Line Tools)
- iPhone con iOS 16+ (opcional, para face-cam)

## Build

```bash
cd ~/Desktop/Tools/Markzzy
swift build -c release
```

El binario queda en `.build/release/Markzzy`.

## Tests

```bash
swift test                              # unit + E2E
swift test --filter MarkzzyE2ETests       # solo E2E
```

El test E2E inyecta frames sintéticos por toda la pipeline
(compositor PIP → AVAssetWriter → .mp4) y verifica que el archivo
de salida abre, tiene pistas de video y audio, y la duración correcta.

## Instalar icono en Escritorio

```bash
./scripts/install-to-desktop.sh
```

Esto genera el icono, crea `Markzzy.app` en `~/Desktop` y copia el
binario dentro del bundle (si está compilado).

## Arquitectura

```
Sources/Markzzy/
├── MarkzzyApp.swift           @main SwiftUI
├── AppModel.swift           estado global observable
├── Permissions.swift        TCC (screen/cam/mic)
├── Capture/
│   ├── ScreenCapture.swift  ScreenCaptureKit
│   ├── CameraCapture.swift  AVFoundation (incluye Continuity)
│   └── AudioCapture.swift   AVCaptureAudioDataOutput
├── Composition/
│   └── PIPCompositor.swift  CoreImage blend screen + cam
├── Recording/
│   └── Recorder.swift       AVAssetWriter → .mp4
└── Views/
    ├── ControlPanel.swift   UI principal
    └── PIPPreview.swift     preview overlay
```
