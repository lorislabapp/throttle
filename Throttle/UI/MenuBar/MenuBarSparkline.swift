import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let devUnlockChanged = Notification.Name("com.lorislab.throttle.dev-unlock-changed")
}

// MARK: - Sparkline

/// Tiny line+area chart for arrays of non-negative values. Implemented
/// with `Shape` (Core Animation) instead of `Canvas` (Metal/RenderBox),
/// because Canvas inside MenuBarExtra `.window` style crashes the
/// dropdown on macOS 26.5 — the regression that took down 2.0/2.1.
/// Path-based shapes go through CGContext, not the Metal pipeline,
/// and survive the regression. All-zero arrays render an empty flat
/// baseline rather than a divide-by-zero crash.
struct Sparkline: View {
    let values: [Int]
    let stroke: Color
    let fill: Color

    var body: some View {
        ZStack {
            SparklineArea(values: values).fill(fill)
            SparklineLine(values: values).stroke(
                stroke,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

struct SparklineArea: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2 else { return p }
        let pts = sparklinePoints(values: values, in: rect)
        p.move(to: CGPoint(x: 0, y: rect.height))
        for c in pts { p.addLine(to: c) }
        p.addLine(to: CGPoint(x: rect.width, y: rect.height))
        p.closeSubpath()
        return p
    }
}

struct SparklineLine: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2 else { return p }
        let pts = sparklinePoints(values: values, in: rect)
        p.move(to: pts[0])
        for c in pts.dropFirst() { p.addLine(to: c) }
        return p
    }
}

private func sparklinePoints(values: [Int], in rect: CGRect) -> [CGPoint] {
    let maxV = max(values.max() ?? 0, 1)
    let stepX = rect.width / CGFloat(values.count - 1)
    return values.enumerated().map { i, v in
        let x = CGFloat(i) * stepX
        let y = rect.height - (CGFloat(v) / CGFloat(maxV)) * rect.height
        return CGPoint(x: x, y: y)
    }
}

// MARK: - InlineAssistantPane
