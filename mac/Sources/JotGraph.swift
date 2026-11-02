// Jot graph: every note as a dot, [[links]] as lines, mentions + related notes (autoEdges) as faint lines, laid out by a small force simulation. macOS only.
// Click a dot to open the note in the panel; drag dots or the background; pinch / scroll-zoom with ⌥ or the buttons.
import AppKit
import SwiftUI

final class GraphSim {
    struct Node { let id: String; var title: String; var p: CGPoint; var v: CGVector = .zero; var deg = 0; var soft = 0; var fixed = false }
    var nodes: [Node] = []
    var edges: [(Int, Int)] = []
    var softEdges: [(a: Int, b: Int, mention: Bool)] = []   // autoEdges: weaker pull, drawn faint (related dashed)
    var slot: [String: Int] = [:]
    var heat = 1.0

    func rebuild(_ ix: NotesIndex) {
        var old: [String: Node] = [:]
        for n in nodes { old[n.id] = n }
        nodes = ix.order.map { id in
            var n = old[id] ?? Node(id: id, title: "", p: CGPoint(x: Double.random(in: -200...200), y: Double.random(in: -200...200)))
            n.title = ix.notes[id]?.title ?? ""; n.deg = 0; n.soft = 0; n.fixed = false
            return n
        }
        slot = [:]
        for (i, n) in nodes.enumerated() { slot[n.id] = i }
        edges = ix.edges().compactMap { e in
            guard let a = slot[e.0], let b = slot[e.1] else { return nil }
            return (a, b)
        }
        for (a, b) in edges { nodes[a].deg += 1; nodes[b].deg += 1 }
        softEdges = ix.autoEdges().compactMap { e in
            guard let a = slot[e.a], let b = slot[e.b] else { return nil }
            return (a, b, e.kind == "mention")
        }
        for e in softEdges { nodes[e.a].soft += 1; nodes[e.b].soft += 1 }
        heat = 1
    }

    /// one step; returns false once everything has settled
    func step() -> Bool {
        guard heat > 0.004, !nodes.isEmpty else { return false }
        let n = nodes.count
        var f = [CGVector](repeating: .zero, count: n)
        let rep = 2600.0, spring = 0.035, rest = 70.0, grav = 0.012
        for i in 0..<n {
            for j in (i + 1)..<n where j < n {
                var dx = nodes[i].p.x - nodes[j].p.x, dy = nodes[i].p.y - nodes[j].p.y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = Double.random(in: -1...1); dy = Double.random(in: -1...1); d2 = 1 }
                if d2 > 250_000 { continue }
                let k = rep / d2, d = d2.squareRoot()
                f[i].dx += k * dx / d; f[i].dy += k * dy / d
                f[j].dx -= k * dx / d; f[j].dy -= k * dy / d
            }
        }
        for (a, b) in edges {
            let dx = nodes[b].p.x - nodes[a].p.x, dy = nodes[b].p.y - nodes[a].p.y
            let d = max((dx * dx + dy * dy).squareRoot(), 0.1), k = spring * (d - rest)
            f[a].dx += k * dx / d; f[a].dy += k * dy / d
            f[b].dx -= k * dx / d; f[b].dy -= k * dy / d
        }
        for e in softEdges {
            let dx = nodes[e.b].p.x - nodes[e.a].p.x, dy = nodes[e.b].p.y - nodes[e.a].p.y
            let d = max((dx * dx + dy * dy).squareRoot(), 0.1), k = spring * 0.35 * (d - rest * 1.6)
            f[e.a].dx += k * dx / d; f[e.a].dy += k * dy / d
            f[e.b].dx -= k * dx / d; f[e.b].dy -= k * dy / d
        }
        var moved = 0.0
        for i in 0..<n where !nodes[i].fixed {
            f[i].dx -= nodes[i].p.x * grav; f[i].dy -= nodes[i].p.y * grav
            nodes[i].v.dx = (nodes[i].v.dx + f[i].dx) * 0.6
            nodes[i].v.dy = (nodes[i].v.dy + f[i].dy) * 0.6
            let sp = (nodes[i].v.dx * nodes[i].v.dx + nodes[i].v.dy * nodes[i].v.dy).squareRoot()
            if sp > 30 { nodes[i].v.dx *= 30 / sp; nodes[i].v.dy *= 30 / sp }
            nodes[i].p.x += nodes[i].v.dx * heat; nodes[i].p.y += nodes[i].v.dy * heat
            moved += sp
        }
        heat *= 0.992
        if moved / Double(n) < 0.05 { heat = 0 }
        return true
    }
    func radius(_ n: Node) -> Double { 3.5 + min(Double(n.deg), 16).squareRoot() * 1.8 }
}

struct GraphView: View {
    @EnvironmentObject var model: AppModel
    @State private var sim = GraphSim()
    @State private var offset = CGSize.zero
    @State private var dragBase = CGSize.zero
    @State private var scale: CGFloat = 1
    @State private var scaleBase: CGFloat = 1
    @State private var hover: Int?
    @State private var dragging: Int?
    @State private var ticks = 0
    @State private var settled = false
    @State private var filter = ""

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + offset.width, y: geo.size.height / 2 + offset.height)
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: settled && dragging == nil)) { tl in
                    Canvas { ctx, size in
                        _ = tl.date
                        if !sim.step() && !settled { DispatchQueue.main.async { settled = true } }
                        draw(ctx, center: center)
                    }
                }
                .contentShape(Rectangle())
                .gesture(drag(center: center))
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { v in scale = min(max(scaleBase * v, 0.2), 5) }
                    .onEnded { _ in scaleBase = scale })
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hover = hit(p, center: center) } else { hover = nil }
                }
                controls
            }
        }
        .onAppear { relayout() }
        .onChange(of: model.indexGen) { _ in relayout() }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var controls: some View {
        HStack(spacing: 8) {
            TextField("Highlight…", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            Button { scale = min(scale * 1.25, 5); scaleBase = scale } label: { Image(systemName: "plus.magnifyingglass") }
            Button { scale = max(scale / 1.25, 0.2); scaleBase = scale } label: { Image(systemName: "minus.magnifyingglass") }
            Button { offset = .zero; dragBase = .zero; scale = 1; scaleBase = 1 } label: { Image(systemName: "scope") }.help("Center")
            Button { relayout() } label: { Image(systemName: "arrow.clockwise") }.help("Lay out again")
            Text("\(sim.nodes.count) notes · \(sim.edges.count) links · \(sim.softEdges.count) related").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    func relayout() { sim.rebuild(model.index); ticks += 1; settled = false }

    func toWorld(_ p: CGPoint, center: CGPoint) -> CGPoint { CGPoint(x: (p.x - center.x) / scale, y: (p.y - center.y) / scale) }
    func toScreen(_ p: CGPoint, center: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * scale, y: center.y + p.y * scale) }
    func hit(_ p: CGPoint, center: CGPoint) -> Int? {
        let w = toWorld(p, center: center)
        var best: Int?, bd = Double.infinity
        for (i, n) in sim.nodes.enumerated() {
            let d = hypot(n.p.x - w.x, n.p.y - w.y)
            if d < max(sim.radius(n) + 4, 8 / scale) && d < bd { best = i; bd = d }
        }
        return best
    }

    func drag(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragging == nil && hypot(v.translation.width, v.translation.height) < 3 {
                    if let i = hit(v.startLocation, center: center) { dragging = i }
                    else { dragging = -1 }
                }
                if let i = dragging, i >= 0, i < sim.nodes.count {
                    sim.nodes[i].p = toWorld(v.location, center: center); sim.nodes[i].fixed = true; sim.heat = max(sim.heat, 0.3); settled = false
                } else {
                    offset = CGSize(width: dragBase.width + v.translation.width, height: dragBase.height + v.translation.height)
                }
            }
            .onEnded { v in
                let tap = hypot(v.translation.width, v.translation.height) < 3
                if let i = dragging, i >= 0, i < sim.nodes.count {
                    sim.nodes[i].fixed = false
                    if tap { NotificationCenter.default.post(name: .jotShowPanel, object: sim.nodes[i].id) }   // opens in the last-used window
                } else { dragBase = offset }
                dragging = nil
            }
    }

    func draw(_ ctx: GraphicsContext, center: CGPoint) {
        let nodes = sim.nodes
        let current = sim.slot[model.currentId]
        let focus = hover ?? current
        var near = Set<Int>()
        if let f = focus { near.insert(f); for (a, b) in sim.edges + sim.softEdges.map({ ($0.a, $0.b) }) where a == f || b == f { near.insert(a); near.insert(b) } }
        let fq = Logic.titleKey(filter)
        let match: (GraphSim.Node) -> Bool = { fq.isEmpty || Logic.titleKey($0.title).contains(fq) }

        var softLine = Path(), softDash = Path(), softHot = Path()
        for e in sim.softEdges {
            let pa = toScreen(nodes[e.a].p, center: center), pb = toScreen(nodes[e.b].p, center: center)
            if focus != nil && (e.a == focus || e.b == focus) { softHot.move(to: pa); softHot.addLine(to: pb) }
            else if e.mention { softLine.move(to: pa); softLine.addLine(to: pb) }
            else { softDash.move(to: pa); softDash.addLine(to: pb) }
        }
        let softAlpha = focus == nil ? 0.2 : 0.07
        ctx.stroke(softLine, with: .color(.secondary.opacity(softAlpha)), lineWidth: 0.75)
        ctx.stroke(softDash, with: .color(.secondary.opacity(softAlpha)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
        ctx.stroke(softHot, with: .color(.accentColor.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        var faint = Path(), strong = Path()
        for (a, b) in sim.edges {
            let pa = toScreen(nodes[a].p, center: center), pb = toScreen(nodes[b].p, center: center)
            if focus != nil && (a == focus || b == focus) { strong.move(to: pa); strong.addLine(to: pb) }
            else { faint.move(to: pa); faint.addLine(to: pb) }
        }
        ctx.stroke(faint, with: .color(.secondary.opacity(focus == nil ? 0.35 : 0.15)), lineWidth: 1)
        ctx.stroke(strong, with: .color(.accentColor.opacity(0.8)), lineWidth: 1.5)

        for (i, n) in nodes.enumerated() {
            let p = toScreen(n.p, center: center), r = sim.radius(n) * Double(max(min(scale, 2), 0.6))
            let dimmed = (focus != nil && !near.contains(i)) || !match(n)
            let color: Color = i == current ? .accentColor : n.deg + n.soft == 0 ? .gray : .primary
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(dimmed ? 0.25 : 0.85)))
            let showLabel = near.contains(i) || scale > 1.4 || n.deg >= 4 || (!fq.isEmpty && match(n))
            if showLabel {
                ctx.draw(Text(n.title).font(.system(size: 11, weight: i == focus ? .semibold : .regular)).foregroundColor(dimmed ? .secondary : .primary),
                         at: CGPoint(x: p.x, y: p.y + r + 8), anchor: .center)
            }
        }
    }
}

extension Notification.Name { static let jotShowPanel = Notification.Name("jotShowPanel") }   // object: a note id to open, or nil
