import AppKit
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
    @State private var selected: String?
    @State private var search = ""
    @State private var mouse: CGPoint = .init(x: -1, y: -1)
    /// Mirrors `sim.settled` so the timeline can stop. Flipped at most twice per
    /// load, never per frame.
    @State private var settled = false

    private let code = Color(red: 1.0, green: 0.42, blue: 0.27)
    private let research = Color(red: 0.22, green: 0.78, blue: 0.66)

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Paused once the layout stops moving. This ran at 60 fps
                    // for as long as the cockpit was open: `step()` is O(n²)
                    // over every node pair, so a settled graph nobody was
                    // looking at still cost ~28% of a core indefinitely
                    // (measured 2026-08-22, 46 min uptime, 2.2 GB peak
                    // footprint). A force-directed layout converges in a couple
                    // of seconds; there is nothing to compute after that.
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled)) { _ in
                        Canvas { ctx, size in
                            sim.ensure(size: size)
                            sim.step()
                            draw(ctx, size: size)
                            if sim.settled != settled { settled = sim.settled }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): mouse = p; hover = sim.nearest(to: p)
                        case .ended:         hover = nil; mouse = .init(x: -1, y: -1)
                        }
                    }
                    .onTapGesture {
                        if let hover { selected = selected == hover ? nil : hover }
                    }
                    if loading { ProgressView("Scanning ~/GitHub…").controlSize(.small).padding(20) }
                    if let h = hover, let n = sim.node(h) { tooltip(n).offset(tooltipOffset(h, geo.size)) }
                    if let selected, let node = sim.node(selected) {
                        inspector(node)
                            .frame(width: min(330, max(250, geo.size.width * 0.34)))
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
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
            TextField("Find app, code or research", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .onSubmit { selectFirstMatch() }
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
        let matches = matchingIDs
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
            let dimForHover = hv != nil && n.id != hv && !nb.contains(n.id)
            let dimForSearch = !search.isEmpty && !matches.contains(n.id)
            let dim = dimForHover || dimForSearch
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

    private var matchingIDs: Set<String> {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Set(sim.nodes.lazy.filter {
            $0.label.localizedCaseInsensitiveContains(needle)
                || $0.locations.contains(where: { $0.localizedCaseInsensitiveContains(needle) })
        }.map(\.id))
    }

    private func selectFirstMatch() {
        selected = sim.nodes.first(where: { matchingIDs.contains($0.id) })?.id
    }

    private func inspector(_ node: PortfolioNode) -> some View {
        let neighbours = sim.neighbours(of: node.id)
            .compactMap(sim.node)
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.kind.rawValue.uppercased())
                        .font(.caption2.weight(.bold)).foregroundStyle(color(node))
                    Text(node.label).font(.headline).textSelection(.enabled)
                }
                Spacer()
                Button { selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close inspector")
            }
            Text("\(neighbours.count) backlinks · \(node.locations.count) source locations")
                .font(.caption).foregroundStyle(.secondary)

            if !neighbours.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BACKLINKS").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    Text(neighbours.prefix(12).map(\.label).joined(separator: " · "))
                        .font(.caption).textSelection(.enabled)
                }
            }
            if !node.locations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SOURCES").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    ForEach(Array(node.locations.prefix(6)), id: \.self) { location in
                        Button {
                            let root = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent("GitHub", isDirectory: true)
                            NSWorkspace.shared.open(root.appendingPathComponent(location))
                        } label: {
                            Text(location).lineLimit(1).truncationMode(.middle)
                                .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain).help("Open local source")
                    }
                }
            }
            Button {
                ResearchVaultWindowController.shared.show(query: node.label)
            } label: {
                Label("Search this in Research Vault", systemImage: "lock.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(radius: 12, y: 4)
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
        selected = nil
        settled = false
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

    /// True when the layout has stopped moving, so the view can stop asking for
    /// frames. Reset by anything that disturbs the layout.
    private(set) var settled = false
    /// Consecutive low-energy steps seen. A few in a row, so one slow frame
    /// mid-convergence does not freeze the graph half-arranged.
    private var calm = 0

    /// Mean kinetic energy per node below which the layout counts as at rest.
    /// Node velocities are damped 0.86 each step, so a converged graph falls
    /// well under this within a second or two.
    private static let restEnergy = 0.02
    private static let framesAtRest = 20

    func seed(_ g: PortfolioGraph) {
        nodes = g.nodes; edges = g.edges
        maxReach = max(1, g.nodes.filter { $0.kind != .app }.map(\.reach).max() ?? 1)
        neighbourMap = [:]
        for e in edges { neighbourMap[e.from, default: []].insert(e.to); neighbourMap[e.to, default: []].insert(e.from) }
        pos = [:]; warm = 0
        calm = 0; settled = false
        seedPositions()
    }

    func ensure(size s: CGSize) {
        guard s != size, s.width > 0 else { return }
        size = s
        calm = 0; settled = false      // a resize moves every node again
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
        guard !settled, size.width > 0, nodes.count > 1 else { return }
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
        var energy = 0.0
        for id in ids {
            guard var p = pos[id] else { continue }
            p.vx += (W/2 - p.x) * 0.0016; p.vy += (H/2 - p.y) * 0.0016
            p.vx *= 0.86; p.vy *= 0.86
            p.x = min(max(22, p.x + p.vx), W - 22); p.y = min(max(22, p.y + p.vy), H - 22)
            pos[id] = p
            energy += p.vx * p.vx + p.vy * p.vy
        }
        warm += 1

        let mean = energy / Double(max(1, ids.count))
        calm = mean < Self.restEnergy ? calm + 1 : 0
        if calm >= Self.framesAtRest { settled = true }
    }
}
