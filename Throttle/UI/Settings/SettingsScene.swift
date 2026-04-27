import SwiftUI

struct SettingsScene: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            CalibrationPane()
                .tabItem { Label("Calibration", systemImage: "speedometer") }
            HooksPane()
                .tabItem { Label("Hooks", systemImage: "link") }
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }
}
