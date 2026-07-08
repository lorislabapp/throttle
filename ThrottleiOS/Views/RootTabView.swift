import SwiftUI

/// Three tabs: live mirror (hero), sessions, history/trends.
struct RootTabView: View {
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
    }
}
