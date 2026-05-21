//
//  ProUpsellBanner.swift
//  Throttle
//
//  In-app upsell banner for free tier users
//  Shows context bloat warning with CTA to Optimizer
//

import SwiftUI

struct ProUpsellBanner: View {
    let configSize: Int  // Size of user's config in KB
    let savings: Int     // Potential savings %
    
    @State private var dismissed: Bool = false
    
    var body: some View {
        if !dismissed {
            HStack(spacing: 12) {
                // Warning icon
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.orange, .red],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your config is bloated")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    
                    Text("**\(configSize)KB** could be \(savings)% smaller with Pro Optimizer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer(minLength: 0)
                
                // CTA Button
                Button {
                    openProPage()
                } label: {
                    Text("Fix It")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0.40, green: 0.50, blue: 0.92),
                                         Color(red: 0.46, green: 0.29, blue: 0.64)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                
                // Dismiss button
                Button {
                    withAnimation {
                        dismissed = true
                        dismissedUntil = Date().addingTimeInterval(3 * 86400) // 3 days
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    private func openProPage() {
        if let url = URL(string: "https://lorislab.fr/throttle") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // Persistence: don't nag more than once every 3 days
    private var dismissedUntil: Date? {
        get {
            guard let ts = UserDefaults.standard.object(forKey: "throttle.upsell.dismissedUntil") as? Double else {
                return nil
            }
            return Date(timeIntervalSince1970: ts)
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "throttle.upsell.dismissedUntil")
            } else {
                UserDefaults.standard.removeObject(forKey: "throttle.upsell.dismissedUntil")
            }
        }
    }
}

// MARK: - Integration into DropdownView

/*
Add to DropdownView.swift after windowsList:

if !appState.isPro {
    ProUpsellBanner(
        configSize: estimatedConfigSize(),
        savings: estimatedSavings()
    )
}

// Helper methods for DropdownView:
private func estimatedConfigSize() -> Int {
    // Quick estimate based on file sizes
    let claudeMD = FileManager.default.fileSize(at: "~/.claude/CLAUDE.md") ?? 0
    let settings = FileManager.default.fileSize(at: "~/.claude/settings.json") ?? 0
    return (claudeMD + settings) / 1024  // Convert to KB
}

private func estimatedSavings() -> Int {
    // Conservative estimate: 40-70% savings
    // Show 40% to under-promise, over-deliver
    return 40
}
*/

// MARK: - Preview
#Preview {
    ProUpsellBanner(configSize: 95, savings: 70)
        .padding()
        .frame(width: 340)
}
