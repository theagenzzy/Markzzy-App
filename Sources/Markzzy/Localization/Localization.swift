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
    case sources, screen, sourceLabel, camera, mic, off, noneOption
    case outputVideo, crop

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

    // Output format / layout
    case formatSection, format
    case formatYouTube, formatReel, formatSquare
    case layout
    case layoutPipOverlay, layoutSplitScreenTop, layoutSplitCamTop
    case layoutCameraOnly, layoutScreenOnly
    case screenAnchor, anchorCenter, anchorLeft, anchorRight
    case resolution
    case faceCamHiddenNote

    // Settings
    case settings, general, language
    case quality, qualityLow, qualityMedium, qualityHigh
    case countdown, countdownOff, countdown3s
    case rememberFaceCam, outputFolder
    case videoRecorder  // subtitle under app name

    // License activation
    case licenseTitle, licenseSubtitle
    case licenseEmail, licenseSendCode, licenseSending
    case licenseCodePrompt, licenseCodeSent, licenseActivate, licenseActivating
    case licenseResendCode, licenseWrongEmail, licenseHaveCode, licenseEnterEmailFirst
    case licenseLinkSent, licenseLinkOpenFromMac
    case licenseNoSubscriptionPrefix, licenseGetItHere
    case licenseExpired, licenseNoSubscription
    case licensePlanPrefix, licenseRenewsOn, licenseSignOut
    case licenseSection, licensePlan, licenseEmailLabel, licenseManageOnWeb
    case licenseSigningOut, licenseNotActive
    case licensePlanTrial, licensePlanMonthly, licensePlanLifetime
    // Returning user (post sign-out)
    case licenseWelcomeBack, licenseWelcomeBackSubtitle
    case licenseSendSignInLink, licenseUseDifferentEmail
    case licenseSignOutConfirmTitle, licenseSignOutConfirmBody, licenseSignOutConfirm

    // Updates
    case checkForUpdates

    // System
    case openSystemSettings

    // Recording transport
    case pauseAction, resumeAction, stopAction, paused

    // Library bulk-select
    case selectAction, doneAction
    case confirmDeleteVideos, deleteCountAction

    // Device filter / hide
    case devicesSection, showAllDevices, showAllDevicesHint
    case hideDeviceFormat, hiddenDevicesHeader, noHiddenDevices, unhideAction
    case lockedDuringRecording
}

public enum L10n {
    private static let table: [AppLanguage: [LKey: String]] = [
        .en: [
            .tabRecord: "Record", .tabLibrary: "Library", .tabSettings: "Settings",
            .facecam: "Face cam", .shape: "Shape", .size: "Size",
            .position: "Position", .border: "Border", .color: "Color",
            .orDragAbove: "or drag above", .customPosition: "Custom (drag the PIP)",
            .metallicPreset: "Metallic preset",
            .sources: "Sources",
            .screen: "Screen", .sourceLabel: "Source",
            .camera: "Camera",
            .mic: "Mic", .off: "Off", .noneOption: "None",
            .outputVideo: "Output", .crop: "crop",
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
            .formatSection: "Format", .format: "Preset",
            .formatYouTube: "YouTube", .formatReel: "Reels", .formatSquare: "Post",
            .layout: "Layout",
            .layoutPipOverlay: "Screen + PIP",
            .layoutSplitScreenTop: "Screen top / Cam bottom",
            .layoutSplitCamTop: "Cam top / Screen bottom",
            .layoutCameraOnly: "Camera only",
            .layoutScreenOnly: "Screen only",
            .screenAnchor: "Crop",
            .anchorCenter: "Center", .anchorLeft: "Left", .anchorRight: "Right",
            .resolution: "Resolution",
            .faceCamHiddenNote: "Face-cam controls apply only to the YouTube preset.",
            .settings: "Settings", .general: "General", .language: "Language",
            .quality: "Quality",
            .qualityLow: "Low", .qualityMedium: "Medium", .qualityHigh: "High",
            .countdown: "Countdown",
            .countdownOff: "Off", .countdown3s: "3 seconds",
            .rememberFaceCam: "Remember face cam settings",
            .outputFolder: "Output folder",
            .videoRecorder: "Screen + face cam recorder",
            .licenseTitle: "Activate your account",
            .licenseSubtitle: "Enter the email you used to subscribe — we'll email you a one-click activation link.",
            .licenseEmail: "Email",
            .licenseSendCode: "Send activation link",
            .licenseSending: "Sending…",
            .licenseCodePrompt: "Open the link from your inbox, or paste the 6-digit code below",
            .licenseCodeSent: "Code sent to %@",
            .licenseActivate: "Activate",
            .licenseActivating: "Activating…",
            .licenseResendCode: "Resend code",
            .licenseWrongEmail: "Wrong email? Start over",
            .licenseHaveCode: "I already have a code",
            .licenseEnterEmailFirst: "Enter your email first.",
            .licenseLinkSent: "We sent an activation link to %@.",
            .licenseLinkOpenFromMac: "Open the email on this Mac and click \"Open Markzzy\". The app will activate automatically.",
            .licenseNoSubscriptionPrefix: "Don't have a subscription yet?",
            .licenseGetItHere: "Get one at markzzy.tech",
            .licenseSection: "License",
            .licensePlan: "Plan",
            .licenseEmailLabel: "Email",
            .licenseManageOnWeb: "Manage on web",
            .licenseSigningOut: "Signing out…",
            .licenseNotActive: "No active license.",
            .licensePlanTrial: "Free trial",
            .licensePlanMonthly: "Monthly",
            .licensePlanLifetime: "Lifetime",
            .licenseExpired: "License expired. Please reactivate.",
            .licenseNoSubscription: "Don't have a subscription yet? Get one at markzzy.tech",
            .licensePlanPrefix: "Plan:",
            .licenseRenewsOn: "Renews on",
            .licenseSignOut: "Sign out",
            .licenseWelcomeBack: "Welcome back",
            .licenseWelcomeBackSubtitle: "We'll email a one-click sign-in link to the address below.",
            .licenseSendSignInLink: "Send sign-in link",
            .licenseUseDifferentEmail: "Use a different email",
            .licenseSignOutConfirmTitle: "Sign out of Markzzy?",
            .licenseSignOutConfirmBody: "You'll need to verify your email again to sign back in on this Mac.",
            .licenseSignOutConfirm: "Sign out",
            .checkForUpdates: "Check for Updates",
            .openSystemSettings: "Open System Settings",
            .pauseAction: "Pause",
            .resumeAction: "Resume",
            .stopAction: "Stop",
            .paused: "PAUSED",
            .selectAction: "Select",
            .doneAction: "Done",
            .confirmDeleteVideos: "Delete %d videos? This cannot be undone.",
            .deleteCountAction: "Delete (%d)",
            .devicesSection: "Devices",
            .showAllDevices: "Show all devices",
            .showAllDevicesHint: "Includes virtual cameras and audio loopbacks (OBS, BlackHole, etc).",
            .hideDeviceFormat: "Hide \"%@\"",
            .hiddenDevicesHeader: "Hidden devices",
            .noHiddenDevices: "No hidden devices.",
            .unhideAction: "Unhide",
            .lockedDuringRecording: "Stop recording to change",
        ],
        .es: [
            .tabRecord: "Grabar", .tabLibrary: "Biblioteca", .tabSettings: "Ajustes",
            .facecam: "Cámara", .shape: "Forma", .size: "Tamaño",
            .position: "Posición", .border: "Borde", .color: "Color",
            .orDragAbove: "o arrastra arriba",
            .customPosition: "Personalizada (arrastra)",
            .metallicPreset: "Estilo metálico",
            .sources: "Fuentes",
            .screen: "Pantalla", .sourceLabel: "Fuente",
            .camera: "Cámara",
            .mic: "Micrófono", .off: "Off", .noneOption: "Ninguna",
            .outputVideo: "Salida", .crop: "crop",
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
            .formatSection: "Formato", .format: "Preset",
            .formatYouTube: "YouTube", .formatReel: "Reels", .formatSquare: "Post",
            .layout: "Distribución",
            .layoutPipOverlay: "Pantalla + PIP",
            .layoutSplitScreenTop: "Pantalla arriba / Cámara abajo",
            .layoutSplitCamTop: "Cámara arriba / Pantalla abajo",
            .layoutCameraOnly: "Solo cámara",
            .layoutScreenOnly: "Solo pantalla",
            .screenAnchor: "Recorte",
            .anchorCenter: "Centro", .anchorLeft: "Izquierda", .anchorRight: "Derecha",
            .resolution: "Resolución",
            .faceCamHiddenNote: "Los controles de cámara aplican solo al preset YouTube.",
            .settings: "Ajustes", .general: "General", .language: "Idioma",
            .quality: "Calidad",
            .qualityLow: "Baja", .qualityMedium: "Media", .qualityHigh: "Alta",
            .countdown: "Cuenta regresiva",
            .countdownOff: "Off", .countdown3s: "3 segundos",
            .rememberFaceCam: "Recordar ajustes de cámara",
            .outputFolder: "Carpeta de salida",
            .videoRecorder: "Grabador de pantalla + cámara",
            .licenseTitle: "Activá tu cuenta",
            .licenseSubtitle: "Ingresá el email que usaste para suscribirte — te enviamos un link para activar la app en un click.",
            .licenseEmail: "Correo electrónico",
            .licenseSendCode: "Enviar link de activación",
            .licenseSending: "Enviando…",
            .licenseCodePrompt: "Abrí el link desde tu email, o pegá el código de 6 dígitos abajo",
            .licenseCodeSent: "Código enviado a %@",
            .licenseActivate: "Activar",
            .licenseActivating: "Activando…",
            .licenseResendCode: "Reenviar código",
            .licenseWrongEmail: "¿Email incorrecto? Empezar de nuevo",
            .licenseHaveCode: "Ya tengo un código",
            .licenseEnterEmailFirst: "Primero ingresá tu email.",
            .licenseLinkSent: "Te enviamos un link de activación a %@.",
            .licenseLinkOpenFromMac: "Abrí el email en esta Mac y hacé click en \"Open Markzzy\". La app se activa sola.",
            .licenseNoSubscriptionPrefix: "¿Todavía sin suscripción?",
            .licenseGetItHere: "Conseguí una en markzzy.tech",
            .licenseSection: "Licencia",
            .licensePlan: "Plan",
            .licenseEmailLabel: "Correo",
            .licenseManageOnWeb: "Gestionar en la web",
            .licenseSigningOut: "Cerrando…",
            .licenseNotActive: "Sin licencia activa.",
            .licensePlanTrial: "Prueba gratis",
            .licensePlanMonthly: "Mensual",
            .licensePlanLifetime: "Vitalicio",
            .licenseExpired: "Licencia expirada. Activá de nuevo.",
            .licenseNoSubscription: "¿Todavía sin suscripción? Conseguí una en markzzy.tech",
            .licensePlanPrefix: "Plan:",
            .licenseRenewsOn: "Renueva el",
            .licenseSignOut: "Cerrar sesión",
            .licenseWelcomeBack: "Bienvenido de vuelta",
            .licenseWelcomeBackSubtitle: "Te enviamos un link de inicio de sesión a la dirección de abajo.",
            .licenseSendSignInLink: "Enviar link de acceso",
            .licenseUseDifferentEmail: "Usar otro correo",
            .licenseSignOutConfirmTitle: "¿Cerrar sesión en Markzzy?",
            .licenseSignOutConfirmBody: "Vas a tener que verificar tu correo de nuevo para volver a entrar en esta Mac.",
            .licenseSignOutConfirm: "Cerrar sesión",
            .checkForUpdates: "Buscar actualizaciones",
            .openSystemSettings: "Abrir Ajustes del sistema",
            .pauseAction: "Pausar",
            .resumeAction: "Reanudar",
            .stopAction: "Detener",
            .paused: "PAUSADO",
            .selectAction: "Seleccionar",
            .doneAction: "Listo",
            .confirmDeleteVideos: "¿Borrar %d videos? Esta acción no se puede deshacer.",
            .deleteCountAction: "Borrar (%d)",
            .devicesSection: "Dispositivos",
            .showAllDevices: "Mostrar todos los dispositivos",
            .showAllDevicesHint: "Incluye cámaras virtuales y loopbacks de audio (OBS, BlackHole, etc).",
            .hideDeviceFormat: "Ocultar \"%@\"",
            .hiddenDevicesHeader: "Dispositivos ocultos",
            .noHiddenDevices: "Sin dispositivos ocultos.",
            .unhideAction: "Mostrar",
            .lockedDuringRecording: "Detené la grabación para cambiar",
        ],
    ]

    public static func t(_ key: LKey, in lang: AppLanguage) -> String {
        table[lang]?[key] ?? table[.en]?[key] ?? key.rawValue
    }
}
