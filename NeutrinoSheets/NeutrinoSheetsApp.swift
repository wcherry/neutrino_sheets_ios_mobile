import SwiftUI
import NeutrinoCore
import NeutrinoAuth
import NeutrinoCrypto
import NeutrinoUI

// MARK: - NeutrinoSheetsApp

/// Composition root. Every service is constructed once here and injected into the view tree;
/// nothing reaches for a singleton.
///
/// The wiring is deliberately explicit rather than hidden behind a container: the services form a
/// small graph with a genuine cycle — the drive service needs the content service, which needs the
/// auth service — and writing it out is what makes that cycle visible and its ownership (`weak`)
/// obvious.
@main
struct NeutrinoSheetsApp: App {

    // MARK: - Services

    // Built in `init()` rather than given default values here: defaults are evaluated before the
    // initializer body runs, and the shared services resolve their Keychain namespace through
    // `NeutrinoApp.current` the moment they are constructed.
    @StateObject private var authService: AuthService
    @StateObject private var settings: AppSettings
    @StateObject private var biometricService: BiometricAuthService
    @StateObject private var deviceSessionService: DeviceSessionService
    @StateObject private var keyProvisioningService: KeyProvisioningService
    @StateObject private var keyVaultService: KeyVaultService
    @StateObject private var driveService: SheetsDriveService
    @StateObject private var contentService: SheetContentService
    @StateObject private var networkMonitor: NetworkMonitor
    @StateObject private var deepLinkRouter: DeepLinkRouter

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Init

    init() {
        // Before anything else. `nsheet.*` is what previous builds wrote, so this reads the
        // existing session and the already-imported encryption key rather than starting cold.
        NeutrinoApp.configure(.sheets)
        NeutrinoBrand.use(.sheets)

        _authService = StateObject(wrappedValue: AuthService())
        _settings = StateObject(wrappedValue: AppSettings())
        _biometricService = StateObject(wrappedValue: BiometricAuthService(
            isFeatureEnabled: FeatureFlags.biometricLock
        ))
        _deviceSessionService = StateObject(wrappedValue: DeviceSessionService())
        _keyProvisioningService = StateObject(wrappedValue: KeyProvisioningService())
        _keyVaultService = StateObject(wrappedValue: KeyVaultService())
        _driveService = StateObject(wrappedValue: SheetsDriveService())
        _contentService = StateObject(wrappedValue: SheetContentService())
        _networkMonitor = StateObject(wrappedValue: NetworkMonitor())
        _deepLinkRouter = StateObject(wrappedValue: DeepLinkRouter())
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(settings)
                .environmentObject(biometricService)
                .environmentObject(deviceSessionService)
                .environmentObject(keyProvisioningService)
                .environmentObject(keyVaultService)
                .environmentObject(driveService)
                .environmentObject(contentService)
                .environmentObject(networkMonitor)
                .environmentObject(deepLinkRouter)
                .preferredColorScheme(settings.theme.colorScheme)
                .onOpenURL { url in
                    guard FeatureFlags.appLinks else { return }
                    deepLinkRouter.handle(url)
                }
                .task { await configure() }
        }
        .onChange(of: scenePhase) { phase in
            handle(phase)
        }
    }

    // MARK: - Wiring

    @MainActor
    private func configure() async {
        // Idempotent: `.task` can run again if the scene is rebuilt, and every assignment here is a
        // plain reference write.
        contentService.authService = authService

        driveService.authService = authService
        driveService.contentService = contentService
        driveService.networkMonitor = networkMonitor

        deviceSessionService.authService = authService

        biometricService.lockOnLaunch()

        // Top up this device's retired keys from the account's key file. Enrolment already does
        // this, so on a healthy install it finds nothing; it is here for the device enrolled before
        // the key file existed, and for the one that was offline when its key arrived. One request,
        // and a failure is not worth surfacing — the next launch tries again.
        KeyFileService.shared.authService = authService
        if authService.isAuthenticated && KeyImportService.hasStoredKeys() {
            Task { try? await KeyFileService.shared.restoreArchivedKeys() }
        }

        // Minting a key and restoring one from a printed kit both talk to the account's key
        // directory, so this needs the same token refresher as everything else.
        keyProvisioningService.authService = authService

        keyVaultService.authService = authService

        if authService.isAuthenticated {
            await authService.refreshTokenIfNeeded()
            // Whether this device still holds the account's key. One GET, and the answer is what
            // turns "No encryption key found" on the first spreadsheet the user opens into a prompt
            // for the encryption password now — see `RootView`.
            await keyVaultService.refresh()
        }
    }

    // MARK: - Lifecycle

    @MainActor
    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            biometricService.sceneDidBecomeActive()
        case .inactive:
            // Fires *before* `.background`, and is when iOS takes the app-switcher snapshot.
            biometricService.sceneDidBecomeInactive()
        case .background:
            biometricService.sceneDidEnterBackground()
        @unknown default:
            break
        }
    }
}

// MARK: - RootView

/// Chooses between the login screen, the app, and the lock overlay, and owns the prompt that asks
/// a newly signed-in device for the account's encryption key.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var biometricService: BiometricAuthService
    @EnvironmentObject private var keyVaultService: KeyVaultService

    @State private var showsUnlock = false
    /// Offered once per launch. Somebody who dismissed it gets back through
    /// Settings › Encryption, and every spreadsheet that needs the key still says so when opened.
    @State private var hasOfferedUnlock = false

    var body: some View {
        ZStack {
            if authService.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }

            // Drawn over everything, including the login screen: the switcher snapshot is taken
            // regardless of which one is showing.
            if biometricService.shouldPresentOverlay {
                LockScreenView(biometricService: biometricService)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: biometricService.shouldPresentOverlay)
        .sheet(isPresented: $showsUnlock) {
            VaultUnlockView()
                .environmentObject(keyVaultService)
        }
        // Prompted rather than blocked, matching the other Neutrino apps. The browser still
        // lists spreadsheets and Settings still opens — which matters, because the key file and
        // recovery kit routes live there — so a hard gate would lock the user out of their own way
        // back in. Only `.locked` prompts: `.unreachable` means the server never answered, which
        // is no evidence that this device has the wrong key.
        .onChange(of: keyVaultService.status) { status in
            guard status == .locked, !hasOfferedUnlock else { return }
            hasOfferedUnlock = true
            showsUnlock = true
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            guard isAuthenticated else {
                // The next account to sign in here must be asked about its own vault rather than
                // judged against the one that just left.
                keyVaultService.reset()
                return
            }
            // The launch-time refresh in `configure()` is skipped for a signed-out start, so this
            // is the only one a fresh sign-in gets.
            hasOfferedUnlock = false
            Task { await keyVaultService.refresh() }
        }
    }
}
