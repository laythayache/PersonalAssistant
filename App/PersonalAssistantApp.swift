import SwiftUI
import SwiftData

@main
struct PersonalAssistantApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(PersistenceController.container)
    }
}

struct RootView: View {
    @State private var engine = AssistantEngine(context: PersistenceController.container.mainContext)
    @State private var router = AppRouter.shared
    @State private var hasBootstrapped = false
    @Environment(\.scenePhase) private var scenePhase

    @Query private var settingsRows: [AppSettings]

    private var needsOnboarding: Bool {
        guard let settings = settingsRows.first else { return true }
        return !settings.hasCompletedOnboarding
    }

    var body: some View {
        Group {
            if needsOnboarding {
                OnboardingScreen(engine: engine)
            } else {
                ChatScreen(engine: engine, router: router)
            }
        }
        .task {
            guard !hasBootstrapped else { return }
            hasBootstrapped = true
            await engine.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, hasBootstrapped else { return }
            Task {
                await engine.refresh()
                router.drainPendingRoute()
            }
        }
    }
}
