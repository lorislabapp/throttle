import SwiftUI

/// App Store surface: usage, LAN-paired Mac sessions, and local history.
/// Off-LAN Edge control remains a macOS/direct-distribution capability; exposing
/// a cloud thin-client path here would conflict with App Review guideline 4.2.7.
struct RootTabView: View {
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: OnboardingView.doneKey)

    var body: some View {
        TabView {
            LiveUsageView()
                .tabItem { Label("Usage", systemImage: "gauge.with.needle") }
            SessionListView()
                .tabItem { Label("Sessions", systemImage: "terminal") }
            HistoryChartsView()
                .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
        }
        .tint(MirrorUI.accent)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .presentationDragIndicator(.visible)
        }
    }
}
