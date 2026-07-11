import SwiftUI

/// Three tabs: live mirror (hero), sessions, history/trends.
struct RootTabView: View {
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: OnboardingView.doneKey)

    var body: some View {
        TabView {
            LiveUsageView()
                .tabItem { Label("Usage", systemImage: "gauge.with.needle") }
            SessionListView()
                .tabItem { Label("Sessions", systemImage: "terminal") }
            EdgeSessionListView()
                .tabItem { Label("Edge", systemImage: "server.rack") }
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
