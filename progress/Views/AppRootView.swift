import SwiftUI

@MainActor
struct AppRootView: View {
    @ObservedObject var persistenceController: PersistenceController
    let tipStore: TipStore
    let onPersistenceLoaded: @MainActor () -> Void

    // Snapshot for this window so scheduling a replay in Settings takes effect
    // on the next launch without interrupting the current session.
    @State private var showsIntroduction = !UserDefaults.standard.bool(forKey: IntroductionPreferences.completedKey)

    var body: some View {
        ZStack {
            if showsIntroduction {
                IntroductionView(onFinish: completeIntroduction)
                    .transition(.opacity)
                    .zIndex(1)
            } else {
                PersistenceRootView(persistenceController: persistenceController)
                    .transition(.opacity)
            }
        }
        .statusBarHidden(showsIntroduction)
        .environment(tipStore)
        .task {
            guard !StorageTestConfiguration.isIsolatedHost else { return }
            await tipStore.observeTransactions()
        }
        .animation(.easeOut(duration: 0.2), value: showsIntroduction)
        .task(id: persistenceController.loadState) {
            guard persistenceController.isLoaded else { return }
            onPersistenceLoaded()
        }
    }

    private func completeIntroduction() {
        UserDefaults.standard.set(true, forKey: IntroductionPreferences.completedKey)
        showsIntroduction = false
    }
}
