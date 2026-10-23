import SwiftUI

/// Root — the floating-nav shell, with the first-run onboarding/pairing wizard overlaid until complete.
struct ContentView: View {
    // Persisted flag: onboarding shows only on first launch.
    @AppStorage("noop.onboarded") private var onboarded = false
    var body: some View {
        ZStack {
            RootView()
            // The wizard is layered over the app (not a separate screen), so the app loads underneath while the user pairs.
            if !onboarded {
                OnboardingWizard(onFinished: { onboarded = true })
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarded)
    }
}
