import SwiftUI

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

    @StateObject private var authService = AuthService()
    @StateObject private var settings = AppSettings()
    @StateObject private var biometricService = BiometricAuthService()
    @StateObject private var deviceSessionService = DeviceSessionService()
    @StateObject private var driveService = SheetsDriveService()
    @StateObject private var contentService = SheetContentService()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var deepLinkRouter = DeepLinkRouter()

    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(settings)
                .environmentObject(biometricService)
                .environmentObject(deviceSessionService)
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

        if authService.isAuthenticated {
            await authService.refreshTokenIfNeeded()
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

/// Chooses between the login screen, the app, and the lock overlay.
private struct RootView: View {

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var biometricService: BiometricAuthService

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
    }
}
