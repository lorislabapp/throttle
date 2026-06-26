import SwiftUI

/// Honest heads-up shown only on a bleeding-edge macOS (major ≥ 27, not yet GA),
/// where the embedded terminal can lag under memory pressure. NotebookLM design:
/// graphite (no red), names the cause as environmental (not a Throttle bug),
/// points at quiet mode, and is permanently dismissible per major version. We do
/// NOT claim "beta" (no clean API for it) — we key on the OS major only.
struct OSIssueBanner: View {
    /// Stores the major version the user dismissed this for (0 = never dismissed).
    @AppStorage("osIssueBannerDismissedMajor") private var dismissedMajor = 0

    private var currentMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }
    private var shouldShow: Bool { currentMajor >= 27 && dismissedMajor != currentMajor }

    var body: some View {
        if shouldShow {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Heads-up — on macOS \(currentMajor), the embedded terminal can lag (scroll/typing) under memory pressure. It's a system + swap issue, not a Throttle bug; quiet mode reduces it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button { dismissedMajor = currentMajor } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).help("Dismiss for macOS \(currentMajor)")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
    }
}
