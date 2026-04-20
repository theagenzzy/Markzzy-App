import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case en, es
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .en: "English"
        case .es: "Español"
        }
    }
}

public enum LKey: String, CaseIterable {
    // Tabs
    case tabRecord, tabLibrary, tabSettings

    // Face cam section
    case facecam, shape, size, position, border, color
    case orDragAbove, customPosition, metallicPreset

    // Sources section
    case sources, screen, camera, mic, off, noneOption

    // Shape labels
    case shapeCircle, shapeRectangle, shapeRoundedRect
    case shapeSquircle, shapeHexagon, shapeSoftEdge

    // Border style labels
    case borderNone, borderSolid, borderGradient
    case borderChrome, borderNeon, borderGlow

    // Recording status
    case startRecording, stopRecording
    case savesTo, preparing, recording, saving, errorPrefix
    case showInFinder, screenPreview, recordingIn

    // Library
    case library, videosCount, videoCount
    case noRecordingsYet, videosAppearHere, reload
    case confirmDeleteVideo, deleteAction, cancelAction, watchAction
    case openFolderInFinder, chooseThisFolder, selectFolderMessage, changeFolder

    // Settings
    case settings, general, language
    case quality, qualityLow, qualityMedium, qualityHigh
    case countdown, countdownOff, countdown3s
    case rememberFaceCam, outputFolder
    case videoRecorder  // subtitle under app name
}

public enum L10n {
    private static let table: [AppLanguage: [LKey: String]] = [
        .en: [
            .tabRecord: "Record", .tabLibrary: "Library", .tabSettings: "Settings",
            .facecam: "Face cam", .shape: "Shape", .size: "Size",
            .position: "Position", .border: "Border", .color: "Color",
            .orDragAbove: "or drag above", .customPosition: "Custom (drag the PIP)",
            .metallicPreset: "Metallic preset",
            .sources: "Sources", .screen: "Screen", .camera: "Camera",
            .mic: "Mic", .off: "Off", .noneOption: "None",
            .shapeCircle: "Circle", .shapeRectangle: "Rectangle",
            .shapeRoundedRect: "Rounded", .shapeSquircle: "Squircle",
            .shapeHexagon: "Hexagon", .shapeSoftEdge: "Soft",
            .borderNone: "None", .borderSolid: "Solid", .borderGradient: "Gradient",
            .borderChrome: "Chrome", .borderNeon: "Neon", .borderGlow: "Glow",
            .startRecording: "Start Recording", .stopRecording: "Stop Recording",
            .savesTo: "Saves to",
            .preparing: "Preparing…", .recording: "Recording",
            .saving: "Saving…", .errorPrefix: "Error:",
            .showInFinder: "Show in Finder", .screenPreview: "Screen preview",
            .recordingIn: "Recording in",
            .library: "Library", .videosCount: "videos", .videoCount: "video",
            .noRecordingsYet: "No recordings yet",
            .videosAppearHere: "Your videos will appear here after recording.",
            .reload: "Reload",
            .confirmDeleteVideo: "Delete this video?",
            .deleteAction: "Delete", .cancelAction: "Cancel", .watchAction: "Watch",
            .openFolderInFinder: "Open folder in Finder",
            .chooseThisFolder: "Choose this folder",
            .selectFolderMessage: "Select where to save videos",
            .changeFolder: "Change…",
            .settings: "Settings", .general: "General", .language: "Language",
            .quality: "Quality",
            .qualityLow: "Low", .qualityMedium: "Medium", .qualityHigh: "High",
            .countdown: "Countdown",
            .countdownOff: "Off", .countdown3s: "3 seconds",
            .rememberFaceCam: "Remember face cam settings",
            .outputFolder: "Output folder",
            .videoRecorder: "Screen + face cam recorder",
        ],
        .es: [
            .tabRecord: "Grabar", .tabLibrary: "Biblioteca", .tabSettings: "Ajustes",
            .facecam: "Cámara", .shape: "Forma", .size: "Tamaño",
            .position: "Posición", .border: "Borde", .color: "Color",
            .orDragAbove: "o arrastra arriba",
            .customPosition: "Personalizada (arrastra)",
            .metallicPreset: "Estilo metálico",
            .sources: "Fuentes", .screen: "Pantalla", .camera: "Cámara",
            .mic: "Micrófono", .off: "Off", .noneOption: "Ninguna",
            .shapeCircle: "Círculo", .shapeRectangle: "Rectángulo",
            .shapeRoundedRect: "Redondeada", .shapeSquircle: "Squircle",
            .shapeHexagon: "Hexágono", .shapeSoftEdge: "Suave",
            .borderNone: "Ninguno", .borderSolid: "Sólido", .borderGradient: "Gradiente",
            .borderChrome: "Cromado", .borderNeon: "Neón", .borderGlow: "Brillo",
            .startRecording: "Grabar", .stopRecording: "Parar",
            .savesTo: "Guarda en",
            .preparing: "Preparando…", .recording: "Grabando",
            .saving: "Guardando…", .errorPrefix: "Error:",
            .showInFinder: "Mostrar en Finder", .screenPreview: "Vista de pantalla",
            .recordingIn: "Empieza en",
            .library: "Biblioteca", .videosCount: "videos", .videoCount: "video",
            .noRecordingsYet: "Sin grabaciones aún",
            .videosAppearHere: "Tus videos aparecerán aquí después de grabar.",
            .reload: "Recargar",
            .confirmDeleteVideo: "¿Eliminar este video?",
            .deleteAction: "Eliminar", .cancelAction: "Cancelar", .watchAction: "Ver",
            .openFolderInFinder: "Abrir carpeta en Finder",
            .chooseThisFolder: "Elegir esta carpeta",
            .selectFolderMessage: "Selecciona la carpeta donde guardar los videos",
            .changeFolder: "Cambiar…",
            .settings: "Ajustes", .general: "General", .language: "Idioma",
            .quality: "Calidad",
            .qualityLow: "Baja", .qualityMedium: "Media", .qualityHigh: "Alta",
            .countdown: "Cuenta regresiva",
            .countdownOff: "Off", .countdown3s: "3 segundos",
            .rememberFaceCam: "Recordar ajustes de cámara",
            .outputFolder: "Carpeta de salida",
            .videoRecorder: "Grabador de pantalla + cámara",
        ],
    ]

    public static func t(_ key: LKey, in lang: AppLanguage) -> String {
        table[lang]?[key] ?? table[.en]?[key] ?? key.rawValue
    }
}
