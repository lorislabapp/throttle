import SwiftUI

/// Obsidian-style force-directed map of the ~/GitHub portfolio, in the cockpit.
/// Apps (blue) link to the code they DUPLICATE (orange) and the research topics they
/// RE-RESEARCH (teal) across projects. Data from `PortfolioMapService`; the physics
/// runs in the Canvas draw loop (fine for a viz of this size).
struct PortfolioGraphView: View {
    @State private var graph: PortfolioGraph?
    @State private var loading = true
    @State private var sim = PortfolioSim()
    @State private var hover: String?
    @State private var mouse: CGPoint = .init(x: -1, y: -1)

    private let code = Color(red: 1.0, green: 0.42, blue: 0.27)
    private let research = Color(red: 0.22, green: 0.78, blue: 0.66)

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                        Canvas { ctx, size in
                            sim.ensure(size: size)
                            sim.step()
                            draw(ctx, size: size)
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): mouse = p; hover = sim.nearest(to: p)
                        case .ended:         hover = nil; mouse = .init(x: -1, y: -1)
                        }
                    }
                    if loading { ProgressView("Scanning ~/GitHub…").controlSize(.small).padding(20) }
                    if let h = hover, let n = sim.node(h) { tooltip(n).offset(tooltipOffset(h, geo.size)) }
                }
            }
        }
        .task { await load() }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PORTFOLIO").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                if let g = graph {
                    Text("\(g.appCount) apps · \(g.codeCount) components copied · \(g.researchCount) topics re-researched · \(g.docCount) research docs")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            legendDot("app", .accentColor); legendDot("duplicated code", code); legendDot("shared research", research)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Rescan ~/GitHub").disabled(loading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.primary.opacity(0.03))
        .overlay(Divider(), alignment: .bottom)
    }

    private func legendDot(_ label: String, _ c: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(c).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary) }
    }

    // MARK: draw

    private func color(_ n: PortfolioNode) -> Color {
        switch n.kind { case .app: return .accentColor; case .code: return code; case .research: return research }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let hv = hover
        let nb = hv.map { sim.neighbours(of: $0) } ?? []
        // edges
        for e in sim.edges {
            guard let a = sim.pos[e.from], let b = sim.pos[e.to] else { continue }
            let on = hv != nil && (e.from == hv || e.to == hv)
            var path = Path(); path.move(to: .init(x: a.x, y: a.y)); path.addLine(to: .init(x: b.x, y: b.y))
            ctx.stroke(path, with: .color(on ? Color.accentColor.opacity(0.55) : Color.gray.opacity(0.10)),
                       lineWidth: on ? 1.6 : 0.7)
        }
        // nodes
        for n in sim.nodes {
            guard let p = sim.pos[n.id] else { continue }
            let dim = hv != nil && n.id != hv && !nb.contains(n.id)
            let r = sim.radius(n)
            let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.fill(ring, with: .color(color(n).opacity(dim ? 0.2 : 1)))
            if n.kind != .app && !dim {
                ctx.stroke(ring, with: .color(color(n).opacity(0.35)), lineWidth: 3)   // soft glow proxy
            }
            let show = n.kind != .app || hv == nil || n.id == hv || nb.contains(n.id) || n.reach >= 4
            if show {
                let label = n.label.count > 20 ? String(n.label.prefix(19)) + "…" : n.label
                let txt = Text(label).font(.system(size: 10.5, weight: n.kind == .app ? .regular : .semibold, design: .monospaced))
                    .foregroundStyle(n.kind == .app ? Color.secondary : Color.primary)
                ctx.draw(txt, at: .init(x: p.x, y: p.y - r - 8), anchor: .center)
            }
            _ = ring
        }
    }

    // MARK: tooltip

    private func tooltip(_ n: PortfolioNode) -> some View {
        let detail: String = n.kind == .app ? "\(n.reach) research docs"
            : n.kind == .code ? "\(n.reach) apps copy this file → LorisLabsKit"
            : "\(n.reach) projects research this → shared knowledge base"
        return VStack(alignment: .leading, spacing: 2) {
            Text(n.label).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .fixedSize()
    }

    private func tooltipOffset(_ id: String, _ size: CGSize) -> CGSize {
        guard let p = sim.pos[id] else { return .zero }
        let x = p.x + 14 > size.width - 200 ? p.x - 200 : p.x + 14
        return CGSize(width: x, height: p.y + 10)
    }

    private func load() async {
        loading = true
        let g = await PortfolioMapService.scan()
        graph = g
        sim.seed(g)
        loading = false
    }
}

/// Physics + hit-testing for the graph. Positions live here; the view drives `step()`
/// from its animation timeline.
@MainActor final class PortfolioSim {
    struct P { var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0 }
    private(set) var nodes: [PortfolioNode] = []
    private(set) var edges: [PortfolioEdge] = []
    private(set) var pos: [String: P] = [:]
    private var neighbourMap: [String: Set<String>] = [:]
    private var maxReach = 1
    private var size: CGSize = .zero
    private var warm = 0

    func seed(_ g: PortfolioGraph) {
        nodes = g.nodes; edges = g.edges
        maxReach = max(1, g.nodes.filter { $0.kind != .app }.map(\.reach).max() ?? 1)
        neighbourMap = [:]
        for e in edges { neighbourMap[e.from, default: []].insert(e.to); neighbourMap[e.to, default: []].insert(e.from) }
        pos = [:]; warm = 0
        seedPositions()
    }

    func ensure(size s: CGSize) {
        guard s != size, s.width > 0 else { return }
        size = s
        if pos.isEmpty || pos.values.allSatisfy({ $0.x == 0 && $0.y == 0 }) { seedPositions() }
    }

    private func seedPositions() {
        guard size.width > 0 else { return }
        for (i, n) in nodes.enumerated() {
            let a = Double(i) / Double(max(1, nodes.count)) * .pi * 2
            let r = n.kind == .app ? 230.0 : 110.0
            pos[n.id] = P(x: size.width / 2 + cos(a) * r, y: size.height / 2 + sin(a) * r)
        }
    }

    func radius(_ n: PortfolioNode) -> CGFloat {
        n.kind == .app ? 4 + CGFloat(min((neighbourMap[n.id]?.count ?? 0), 6))
                       : 7 + CGFloat(Double(n.reach) / Double(maxReach) * 15)
    }
    func node(_ id: String) -> PortfolioNode? { nodes.first { $0.id == id } }
    func neighbours(of id: String) -> Set<String> { neighbourMap[id] ?? [] }

    func nearest(to pt: CGPoint) -> String? {
        var best: String?; var bd = Double.greatestFiniteMagnitude
        for n in nodes { guard let p = pos[n.id] else { continue }
            let d = hypot(p.x - pt.x, p.y - pt.y)
            if d < Double(radius(n)) + 7, d < bd { bd = d; best = n.id } }
        return best
    }

    func step() {
        guard size.width > 0, nodes.count > 1 else { return }
        let W = size.width, H = size.height
        let ids = Array(pos.keys)
        for i in 0..<ids.count {
            for j in (i+1)..<ids.count {
                guard var a = pos[ids[i]], var b = pos[ids[j]] else { continue }
                var dx = a.x - b.x, dy = a.y - b.y
                let d2 = max(0.01, dx*dx + dy*dy), d = sqrt(d2), f = 2500 / d2
                dx /= d; dy /= d
                a.vx += dx*f; a.vy += dy*f; b.vx -= dx*f; b.vy -= dy*f
                pos[ids[i]] = a; pos[ids[j]] = b
            }
        }
        for e in edges {
            guard var a = pos[e.from], var b = pos[e.to] else { continue }
            var dx = b.x - a.x, dy = b.y - a.y
            let d = max(0.01, hypot(dx, dy)), f = (d - 94) * 0.008
            dx /= d; dy /= d
            a.vx += dx*f; a.vy += dy*f; b.vx -= dx*f; b.vy -= dy*f
            pos[e.from] = a; pos[e.to] = b
        }
        for id in ids {
            guard var p = pos[id] else { continue }
            p.vx += (W/2 - p.x) * 0.0016; p.vy += (H/2 - p.y) * 0.0016
            p.vx *= 0.86; p.vy *= 0.86
            p.x = min(max(22, p.x + p.vx), W - 22); p.y = min(max(22, p.y + p.vy), H - 22)
            pos[id] = p
        }
        warm += 1
    }
}
