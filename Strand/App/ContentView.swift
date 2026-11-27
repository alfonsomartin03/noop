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
        .task {
            // Fixture only (`-noop.fixture.appearance dark|light`): force the app's appearance for screenshots.
            if let a = LaunchMode.fixtureAppearance { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
            // Fixture only (`-noop.fixture.width 1000`): resize the window for narrow-width screenshots.
            guard let w = LaunchMode.fixtureWidth else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            var f = win.frame
            f.size.width = CGFloat(w)
            win.setFrame(f, display: true)
        }
    }
}
