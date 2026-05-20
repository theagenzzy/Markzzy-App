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
    case screenAnchor, anchorCenter, anchorLeft, anchorRight, anchorTop, anchorBottom
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
    // Email validation + typo suggestion
    case licenseDidYouMean              // "Did you mean %@?"
    case licenseUseThis                 // "Use this"
    case licenseNoEmailArrivedHint      // "Nothing in 2 minutes? Make sure the email is right or get a sub."
    // Settings subsection tabs
    case sectionGeneral, sectionRecording, sectionCameras, sectionOutput, sectionLicense
    // License hero / details
    case licenseActiveSubtitle, licenseTrialDaysLeft, licenseThisMac, licenseGetHelp
    case copyAction
    // General/Output enrichment
    case appAbout, appVersion, appWhatsNew, appWebsite
    case outputDiskSpace, outputRecordingsCount, outputOpenInFinder
    // Recording quality descriptions
    case qualityLowDesc, qualityMediumDesc, qualityHighDesc

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
    case allowVirtualCameras, allowVirtualCamerasHint
    case detectedCamerasHeader, detectedCamerasHint
    case detectedColumnName, detectedColumnType, detectedColumnRole, detectedColumnStatus
    case roleRealIPhone, roleNativeContinuity, roleBridgedIPhone, roleVirtualBridge, roleStandard
    case statusInUse, statusAvailable, statusFiltered

    // Continuity Camera (iPhone slot in camera picker)
    case cameraIPhoneSlot, cameraIPhoneWaiting

    // iPhone-waiting overlay shown over the preview while we wait for
    // the iPhone to become available.
    case iPhoneWaitingTitle, iPhoneWaitingHint, iPhoneWaitingBridgeNote
    // Variant shown after the user tapped "Disconnect" on the iPhone
    // (or the iPhone otherwise dropped mid-session).
    case iPhoneReconnectingTitle, iPhoneReconnectingHint, iPhoneReconnectingHintShort
    case iPhoneReconnectButton, iPhoneReconnectButtonShort
    // Progress + escalation
    case iPhoneReconnectingAttempt          // "Trying %@…"
    case iPhoneReconnectExhaustedTitle      // "iOS still blocking — waiting for cool-down"
    case iPhoneReconnectExhaustedHint       // typical 1-10 min wait + faster options
    case iPhoneReconnectTryAgain            // "Try again"
    case iPhoneReconnectStillWatching       // "Markzzy will keep checking…"

    // Educational tip in Settings → Cameras
    case continuityTipHeader, continuityTipBody

    // License hero (consolidated status card)
    case licenseHeroTrialEndsToday          // "Trial ends today"
    case licenseHeroOneDayLeft              // "1 day left"
    case licenseHeroDaysLeftFormat          // "%d days left"
    case licenseHeroLifetimeAccess          // "Lifetime access"
    case licenseHeroSubActive               // "Subscription active"
    case licenseHeroChargeOnFormat          // "We'll charge $10 on %@ · cancel any time before then ·"
    case licenseHeroCancelBeforeEnds        // "Cancel before your trial ends and you won't be charged ·"
    case licenseHeroLifetimeBlurb           // "Pay once, use forever. Includes all future updates."
    case licenseHeroNextRenewalFormat       // "Next renewal on %@."
    case licenseHeroUpgradeButton           // "Upgrade · $10/mo"
    case licenseHeroLifetimeUpsell          // "Lifetime $129 →"
    // Hero plan picker (segmented switch between Monthly and Lifetime)
    case licenseHeroPlanPickerLabel         // "Pick a plan to upgrade to"
    case licenseHeroPlanMonthlyLine         // "Mensual · $10/mes"
    case licenseHeroPlanLifetimeLine        // "Vitalicio · $129 una vez"
    case licenseHeroActivatePlan            // "Activar plan →"

    // License: state-driven cards (past due / cancel-at-period-end)
    case licensePastDueTitle                // "⚠️ Payment failed"
    case licensePastDueBody                 // "PayPal is retrying your card…"
    case licenseUpdatePaymentButton         // "Update payment"
    case licenseSubEndsOnFormat             // "Subscription ends %@"
    case licenseReactivateBody              // "Changed your mind? Reactivate any time…"
    case licenseReactivateButton            // "Reactivate"
    case licenseCancelSubscription          // "Cancel subscription"

    // License: What's included card
    case licenseWhatsIncluded
    case licenseFeaturePresets
    case licenseFeatureLayouts
    case licenseFeatureWatermark
    case licenseFeatureLibrary
    case licenseFeatureSupportPaid          // "Priority email support"
    case licenseFeatureSupportTrial         // "Priority email support (Monthly & Lifetime)"

    // License: Compare plans card
    case licenseComparePlans
    case licenseComparePrice
    case licenseCompareBilling
    case licenseCompareUpdates
    case licenseCompareSupport
    case licenseCompareBestFor
    case licenseCompareFree
    case licenseCompareMonthlyPrice         // "$10/mo"
    case licenseCompareLifetimePrice        // "$129"
    case licenseCompareRecurring
    case licenseCompareOneTime
    case licenseComparePriority
    case licenseCompareTesting
    case licenseCompareActiveUse
    case licenseCompareLongTerm

    // Output: Recent recordings + Storage cards
    case outputRecentRecordings
    case outputNoRecordingsYet              // empty state
    case outputStorage
    case outputUsedByMarkzzy
    case outputStorageEstimateFormat        // "At %@ quality, you can record approximately **%@**…"
    case outputStorageLessThanHour
    case outputStorageHoursFormat           // "%d hours"
    case outputStorageDaysFormat            // "%d days"

    // Library — clarity polish (friendly titles, button labels, tooltips)
    case libraryRecordingTitleFormat        // "Recording · %@" (date)
    case libraryEmptyHeadline               // "Your first recording will appear here"
    case libraryEmptySubcopy                // "Switch to the Record tab to capture one."
    case libraryAccountTooltip              // "Account & license"
    case libraryActionPlay                  // "Play"
    case libraryActionShowInFinder          // "Show in Finder"
    case libraryActionDelete                // "Delete"
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
            .anchorTop: "Top", .anchorBottom: "Bottom",
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
            .licenseLinkSent: "If %@ has an active subscription, an activation link is on its way.",
            .licenseLinkOpenFromMac: "Open the email on this Mac and click \"Open Markzzy\" — the app will activate automatically.",
            .licenseDidYouMean: "Did you mean %@?",
            .licenseUseThis: "Use this",
            .licenseNoEmailArrivedHint: "Nothing in a couple of minutes? Double-check the email is right, or get a subscription at markzzy.tech.",
            .sectionGeneral: "General",
            .sectionRecording: "Recording",
            .sectionCameras: "Cameras",
            .sectionOutput: "Output",
            .sectionLicense: "License",
            .licenseActiveSubtitle: "Your subscription is active",
            .licenseTrialDaysLeft: "%d day(s) left in your trial",
            .licenseThisMac: "This Mac",
            .licenseGetHelp: "Get help",
            .copyAction: "Copy",
            .appAbout: "About Markzzy",
            .appVersion: "Version",
            .appWhatsNew: "What's new",
            .appWebsite: "Website",
            .outputDiskSpace: "Free disk space",
            .outputRecordingsCount: "Recordings",
            .outputOpenInFinder: "Open in Finder",
            .qualityLowDesc: "Smaller files. Good for tutorials and screen-only.",
            .qualityMediumDesc: "Balanced quality and file size. Recommended for most.",
            .qualityHighDesc: "Maximum quality. Larger files. Best for camera-heavy content.",
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
            .allowVirtualCameras: "Allow virtual cameras as iPhone",
            .allowVirtualCamerasHint: "Lets the iPhone slot bind to bridge drivers (Camo Camera, EpocCam HD, …) when no real iPhone is detected. Off by default — most users want their real iPhone, not the bridge's virtual camera.",
            .detectedCamerasHeader: "Detected cameras",
            .detectedCamerasHint: "What Markzzy currently sees on your Mac. Useful for diagnosing connection issues.",
            .detectedColumnName: "Name",
            .detectedColumnType: "Type",
            .detectedColumnRole: "Role",
            .detectedColumnStatus: "Status",
            .roleNativeContinuity: "Native Continuity",
            .roleRealIPhone: "Real iPhone",
            .roleBridgedIPhone: "iPhone via bridge",
            .roleVirtualBridge: "Virtual bridge",
            .roleStandard: "Standard camera",
            .statusInUse: "In use",
            .statusAvailable: "Available",
            .statusFiltered: "Filtered out",
            .cameraIPhoneSlot: "iPhone Camera",
            .cameraIPhoneWaiting: "iPhone (waiting…)",
            .iPhoneWaitingTitle: "Looking for your iPhone…",
            .iPhoneWaitingHint: "Wake your iPhone, bring it closer, and make sure Continuity Camera is on in iOS Settings.",
            .iPhoneWaitingBridgeNote: "Detected: %@. If your iPhone is connected through it, it'll appear once it sends frames. To use Apple's native Continuity, quit the app above.",
            .iPhoneReconnectingTitle: "iPhone disconnected",
            .iPhoneReconnectingHint: "Apple imposes a cool-down of up to ~10 minutes after you tap Disconnect. Markzzy will reconnect automatically when iOS allows.\n\nTo speed it up:\n  • Connect your iPhone via USB cable (instant)\n  • Restart your iPhone (always works)",
            .iPhoneReconnectingHintShort: "iOS cool-down up to ~10 min. USB or restart iPhone for instant reconnect.",
            .iPhoneReconnectButton: "Try to reconnect now",
            .iPhoneReconnectButtonShort: "Reconnect",
            .iPhoneReconnectingAttempt: "Trying %@…",
            .iPhoneReconnectExhaustedTitle: "Waiting for iOS cool-down",
            .iPhoneReconnectExhaustedHint: "Typical wait: 1–10 minutes. Markzzy will keep checking automatically.\n\nWhile you wait:\n  ✅ Connect USB for instant reconnection\n  ✅ Restart the iPhone (always works)",
            .iPhoneReconnectTryAgain: "Try again",
            .iPhoneReconnectStillWatching: "Markzzy is still checking — it'll reconnect the moment iOS allows.",
            .continuityTipHeader: "About Continuity Camera",
            .continuityTipBody: "To switch cameras, use the dropdown above.\n\nAvoid tapping \"Disconnect\" on your iPhone — iOS imposes a cool-down of up to ~10 minutes that no app can bypass (it's an Apple privacy protection).\n\nFor uninterrupted professional use, connect your iPhone via USB cable. USB bypasses the cool-down entirely.",

            .licenseHeroTrialEndsToday: "Trial ends today",
            .licenseHeroOneDayLeft: "1 day left",
            .licenseHeroDaysLeftFormat: "%d days left",
            .licenseHeroLifetimeAccess: "Lifetime access",
            .licenseHeroSubActive: "Subscription active",
            .licenseHeroChargeOnFormat: "We'll charge $10 on %@ · cancel any time before then ·",
            .licenseHeroCancelBeforeEnds: "Cancel before your trial ends and you won't be charged ·",
            .licenseHeroLifetimeBlurb: "Pay once, use forever. Includes all future updates.",
            .licenseHeroNextRenewalFormat: "Next renewal on %@.",
            .licenseHeroUpgradeButton: "Upgrade · $10/mo",
            .licenseHeroLifetimeUpsell: "Lifetime $129 →",
            .licenseHeroPlanPickerLabel: "Choose a plan to upgrade to",
            .licenseHeroPlanMonthlyLine: "Monthly · $10/mo",
            .licenseHeroPlanLifetimeLine: "Lifetime · $129 once",
            .licenseHeroActivatePlan: "Activate plan →",

            .licensePastDueTitle: "⚠️ Payment failed",
            .licensePastDueBody: "PayPal is retrying your card. Update your payment method to avoid losing access.",
            .licenseUpdatePaymentButton: "Update payment",
            .licenseSubEndsOnFormat: "Subscription ends %@",
            .licenseReactivateBody: "Changed your mind? Reactivate any time before that date and nothing changes.",
            .licenseReactivateButton: "Reactivate",
            .licenseCancelSubscription: "Cancel subscription",

            .licenseWhatsIncluded: "What's included",
            .licenseFeaturePresets: "All platform presets — TikTok, Reels, Shorts, Stories, YouTube",
            .licenseFeatureLayouts: "5 PIP layouts · Smart crop · Up to 4K capture",
            .licenseFeatureWatermark: "Watermark-free · Unlimited recordings",
            .licenseFeatureLibrary: "Library access · All future updates",
            .licenseFeatureSupportPaid: "Priority email support",
            .licenseFeatureSupportTrial: "Priority email support (Monthly & Lifetime)",

            .licenseComparePlans: "Compare plans",
            .licenseComparePrice: "Price",
            .licenseCompareBilling: "Billing",
            .licenseCompareUpdates: "Updates",
            .licenseCompareSupport: "Support",
            .licenseCompareBestFor: "Best for",
            .licenseCompareFree: "Free",
            .licenseCompareMonthlyPrice: "$10/mo",
            .licenseCompareLifetimePrice: "$129",
            .licenseCompareRecurring: "Recurring",
            .licenseCompareOneTime: "One-time",
            .licenseComparePriority: "Priority",
            .licenseCompareTesting: "Testing",
            .licenseCompareActiveUse: "Active use",
            .licenseCompareLongTerm: "Long-term",

            .outputRecentRecordings: "Recent recordings",
            .outputNoRecordingsYet: "No recordings yet — your captures will appear here.",
            .outputStorage: "Storage",
            .outputUsedByMarkzzy: "Used by Markzzy",
            .outputStorageEstimateFormat: "At %@ quality, you can record approximately **%@** before running out of disk.",
            .outputStorageLessThanHour: "less than an hour",
            .outputStorageHoursFormat: "%d hours",
            .outputStorageDaysFormat: "%d days",

            .libraryRecordingTitleFormat: "Recording · %@",
            .libraryEmptyHeadline: "Your first recording will appear here",
            .libraryEmptySubcopy: "Switch to the Record tab to capture one.",
            .libraryAccountTooltip: "Account & license",
            .libraryActionPlay: "Play",
            .libraryActionShowInFinder: "Finder",
            .libraryActionDelete: "Delete",
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
            .anchorTop: "Arriba", .anchorBottom: "Abajo",
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
            .licenseLinkSent: "Si %@ tiene una suscripción activa, te enviamos un link de activación.",
            .licenseDidYouMean: "¿Quisiste decir %@?",
            .licenseUseThis: "Usar este",
            .licenseNoEmailArrivedHint: "¿Nada en un par de minutos? Verificá que el email esté bien, o conseguí una suscripción en markzzy.tech.",
            .sectionGeneral: "General",
            .sectionRecording: "Grabación",
            .sectionCameras: "Cámaras",
            .sectionOutput: "Salida",
            .sectionLicense: "Licencia",
            .licenseActiveSubtitle: "Tu suscripción está activa",
            .licenseTrialDaysLeft: "%d día(s) restante(s) en tu trial",
            .licenseThisMac: "Esta Mac",
            .licenseGetHelp: "Obtener ayuda",
            .copyAction: "Copiar",
            .appAbout: "Sobre Markzzy",
            .appVersion: "Versión",
            .appWhatsNew: "Novedades",
            .appWebsite: "Sitio web",
            .outputDiskSpace: "Espacio libre en disco",
            .outputRecordingsCount: "Grabaciones",
            .outputOpenInFinder: "Abrir en Finder",
            .qualityLowDesc: "Archivos más chicos. Bien para tutoriales y solo pantalla.",
            .qualityMediumDesc: "Equilibrio entre calidad y tamaño. Recomendado para la mayoría.",
            .qualityHighDesc: "Calidad máxima. Archivos más grandes. Ideal para contenido con mucha cámara.",
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
            .allowVirtualCameras: "Permitir cámaras virtuales como iPhone",
            .allowVirtualCamerasHint: "Hace que el slot iPhone bindee a drivers de puentes (Camo Camera, EpocCam HD, …) cuando no se detecta un iPhone real. Off por defecto — la mayoría quiere su iPhone real, no la cámara virtual del puente.",
            .detectedCamerasHeader: "Cámaras detectadas",
            .detectedCamerasHint: "Lo que Markzzy ve en tu Mac ahora mismo. Útil para diagnosticar problemas de conexión.",
            .detectedColumnName: "Nombre",
            .detectedColumnType: "Tipo",
            .detectedColumnRole: "Rol",
            .detectedColumnStatus: "Estado",
            .roleNativeContinuity: "Continuity nativo",
            .roleRealIPhone: "iPhone real",
            .roleBridgedIPhone: "iPhone vía puente",
            .roleVirtualBridge: "Puente virtual",
            .roleStandard: "Cámara estándar",
            .statusInUse: "En uso",
            .statusAvailable: "Disponible",
            .statusFiltered: "Filtrada",
            .cameraIPhoneSlot: "iPhone Camera",
            .cameraIPhoneWaiting: "iPhone (esperando…)",
            .iPhoneWaitingTitle: "Buscando tu iPhone…",
            .iPhoneWaitingHint: "Despertá tu iPhone, acercalo, y verificá que Continuity Camera esté activa en Ajustes de iOS.",
            .iPhoneWaitingBridgeNote: "Detectado: %@. Si tu iPhone está conectado a través suyo, va a aparecer apenas envíe frames. Para usar Continuity nativa de Apple, cerrá la app de arriba.",
            .iPhoneReconnectingTitle: "iPhone desconectado",
            .iPhoneReconnectingHint: "Apple impone un bloqueo de hasta ~10 minutos después de tocar Disconnect. Markzzy reconectará automáticamente cuando iOS lo permita.\n\nPara acelerar:\n  • Conectá tu iPhone con cable USB (instantáneo)\n  • Reiniciá el iPhone (siempre funciona)",
            .iPhoneReconnectingHintShort: "Bloqueo iOS hasta ~10 min. USB o reinicio del iPhone es instantáneo.",
            .iPhoneReconnectButton: "Intentar reconectar ahora",
            .iPhoneReconnectButtonShort: "Reconectar",
            .iPhoneReconnectingAttempt: "Probando %@…",
            .iPhoneReconnectExhaustedTitle: "Esperando que iOS libere",
            .iPhoneReconnectExhaustedHint: "Tiempo típico: 1–10 minutos. Markzzy seguirá revisando automáticamente.\n\nMientras esperás:\n  ✅ Conectá USB para reconexión instantánea\n  ✅ Reiniciá el iPhone (siempre funciona)",
            .iPhoneReconnectTryAgain: "Intentar de nuevo",
            .iPhoneReconnectStillWatching: "Markzzy sigue revisando — va a reconectar apenas iOS lo permita.",
            .continuityTipHeader: "Sobre Continuity Camera",
            .continuityTipBody: "Para cambiar de cámara, usá el dropdown de arriba.\n\nEvitá tocar \"Disconnect\" en tu iPhone — iOS impone un cool-down de hasta ~10 minutos que ninguna app puede saltear (es protección de privacidad de Apple).\n\nPara uso profesional sin interrupciones, conectá tu iPhone con cable USB. USB bypassea el cool-down completamente.",

            .licenseHeroTrialEndsToday: "El trial termina hoy",
            .licenseHeroOneDayLeft: "1 día restante",
            .licenseHeroDaysLeftFormat: "%d días restantes",
            .licenseHeroLifetimeAccess: "Acceso de por vida",
            .licenseHeroSubActive: "Suscripción activa",
            .licenseHeroChargeOnFormat: "Te cobramos $10 el %@ · cancelá antes y no se te cobra ·",
            .licenseHeroCancelBeforeEnds: "Cancelá antes de que termine el trial y no se te cobra ·",
            .licenseHeroLifetimeBlurb: "Pagá una vez, usalo para siempre. Incluye todas las actualizaciones futuras.",
            .licenseHeroNextRenewalFormat: "Próxima renovación el %@.",
            .licenseHeroUpgradeButton: "Actualizar · $10/mes",
            .licenseHeroLifetimeUpsell: "Vitalicio $129 →",
            .licenseHeroPlanPickerLabel: "Elegí un plan para actualizar",
            .licenseHeroPlanMonthlyLine: "Mensual · $10/mes",
            .licenseHeroPlanLifetimeLine: "Vitalicio · $129 una vez",
            .licenseHeroActivatePlan: "Activar plan →",

            .licensePastDueTitle: "⚠️ Pago fallido",
            .licensePastDueBody: "PayPal está reintentando tu tarjeta. Actualizá el método de pago para no perder el acceso.",
            .licenseUpdatePaymentButton: "Actualizar pago",
            .licenseSubEndsOnFormat: "La suscripción termina el %@",
            .licenseReactivateBody: "¿Cambiaste de opinión? Reactivala antes de esa fecha y nada cambia.",
            .licenseReactivateButton: "Reactivar",
            .licenseCancelSubscription: "Cancelar suscripción",

            .licenseWhatsIncluded: "Qué incluye",
            .licenseFeaturePresets: "Todos los presets — TikTok, Reels, Shorts, Stories, YouTube",
            .licenseFeatureLayouts: "5 layouts PIP · Recorte inteligente · Captura hasta 4K",
            .licenseFeatureWatermark: "Sin marca de agua · Grabaciones ilimitadas",
            .licenseFeatureLibrary: "Acceso a la Biblioteca · Todas las actualizaciones futuras",
            .licenseFeatureSupportPaid: "Soporte por email prioritario",
            .licenseFeatureSupportTrial: "Soporte por email prioritario (Mensual y Vitalicio)",

            .licenseComparePlans: "Comparar planes",
            .licenseComparePrice: "Precio",
            .licenseCompareBilling: "Facturación",
            .licenseCompareUpdates: "Actualizaciones",
            .licenseCompareSupport: "Soporte",
            .licenseCompareBestFor: "Ideal para",
            .licenseCompareFree: "Gratis",
            .licenseCompareMonthlyPrice: "$10/mes",
            .licenseCompareLifetimePrice: "$129",
            .licenseCompareRecurring: "Recurrente",
            .licenseCompareOneTime: "Pago único",
            .licenseComparePriority: "Prioritario",
            .licenseCompareTesting: "Probar",
            .licenseCompareActiveUse: "Uso activo",
            .licenseCompareLongTerm: "Largo plazo",

            .outputRecentRecordings: "Grabaciones recientes",
            .outputNoRecordingsYet: "Aún no hay grabaciones — tus capturas aparecerán acá.",
            .outputStorage: "Almacenamiento",
            .outputUsedByMarkzzy: "Usado por Markzzy",
            .outputStorageEstimateFormat: "A calidad %@, podés grabar aproximadamente **%@** antes de quedarte sin espacio.",
            .outputStorageLessThanHour: "menos de una hora",
            .outputStorageHoursFormat: "%d horas",
            .outputStorageDaysFormat: "%d días",

            .libraryRecordingTitleFormat: "Grabación · %@",
            .libraryEmptyHeadline: "Tu primera grabación aparecerá acá",
            .libraryEmptySubcopy: "Andá a la pestaña Grabar para empezar.",
            .libraryAccountTooltip: "Cuenta y licencia",
            .libraryActionPlay: "Ver",
            .libraryActionShowInFinder: "Finder",
            .libraryActionDelete: "Borrar",
        ],
    ]

    public static func t(_ key: LKey, in lang: AppLanguage) -> String {
        table[lang]?[key] ?? table[.en]?[key] ?? key.rawValue
    }
}
