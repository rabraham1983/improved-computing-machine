import SwiftUI
import CodeScopeCore

/// Dependency graph of internal imports: files are placed on a circle, grouped by top-level
/// directory, with edges drawn between importers and importees.
struct GraphView: View {
    @EnvironmentObject private var appState: AppState
    @State private var hoveredPath: String?
    @State private var maxNodes = 80

    private struct Node: Identifiable {
        let id: String
        let group: String
        let fanIn: Int
        let fanOut: Int
    }

    var body: some View {
        if let index = appState.index {
            let nodes = nodes(for: index)
            let nodeIDs = Set(nodes.map { $0.id })
            let edges = index.edges.filter { nodeIDs.contains($0.from) && nodeIDs.contains($0.to) }
            VStack(spacing: 0) {
                HStack {
                    Text("\(nodes.count) of \(index.files.count) files shown · \(edges.count) internal import edges")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Stepper("Nodes: \(maxNodes)", value: $maxNodes, in: 20...300, step: 20)
                        .font(.caption)
                    if let hoveredPath {
                        Text(hoveredPath).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(10)
                Divider()
                if index.edges.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 36)).foregroundStyle(.tertiary)
                        Text("No internal import relationships were detected.").foregroundStyle(.secondary)
                        Text("The graph is built from import statements that resolve to files inside the project.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        graphCanvas(nodes: nodes, edges: edges, size: geometry.size)
                    }
                    .padding(20)
                }
            }
        } else {
            Text("Open a project to see its dependency graph.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func nodes(for index: ProjectIndex) -> [Node] {
        let connected = index.files
            .map { Node(id: $0.relativePath, group: topLevel($0.relativePath), fanIn: index.fanIn(of: $0.relativePath), fanOut: index.fanOut(of: $0.relativePath)) }
            .filter { $0.fanIn + $0.fanOut > 0 }
            .sorted { lhs, rhs in
                let l = lhs.fanIn + lhs.fanOut
                let r = rhs.fanIn + rhs.fanOut
                return l != r ? l > r : lhs.id < rhs.id
            }
        // Group by directory so related files sit next to each other on the circle.
        return Array(connected.prefix(maxNodes)).sorted { lhs, rhs in
            lhs.group != rhs.group ? lhs.group < rhs.group : lhs.id < rhs.id
        }
    }

    private func topLevel(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count <= 1 { return "." }
        if parts.count >= 3 { return String(parts[0]) + "/" + String(parts[1]) }
        return String(parts[0])
    }

    private func graphCanvas(nodes: [Node], edges: [DependencyEdge], size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(40, min(size.width, size.height) / 2 - 70)
        var positions: [String: CGPoint] = [:]
        for (offset, node) in nodes.enumerated() {
            let angle = (Double(offset) / Double(max(nodes.count, 1))) * 2 * Double.pi - Double.pi / 2
            positions[node.id] = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }
        let groups = Array(Set(nodes.map { $0.group })).sorted()
        let maxFanIn = max(1, nodes.map { $0.fanIn }.max() ?? 1)

        return ZStack {
            Canvas { context, _ in
                for edge in edges {
                    guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                    var path = Path()
                    path.move(to: from)
                    let control = CGPoint(x: (from.x + to.x) / 2 + (center.x - (from.x + to.x) / 2) * 0.35,
                                          y: (from.y + to.y) / 2 + (center.y - (from.y + to.y) / 2) * 0.35)
                    path.addQuadCurve(to: to, control: control)
                    let highlighted = hoveredPath == edge.from || hoveredPath == edge.to
                    let dimmed = hoveredPath != nil && !highlighted
                    context.stroke(path,
                                   with: .color(highlighted ? Color.accentColor : Color.secondary.opacity(dimmed ? 0.08 : 0.3)),
                                   lineWidth: highlighted ? 1.6 : 0.8)
                }
            }
            ForEach(nodes) { node in
                if let position = positions[node.id] {
                    let diameter = 8 + 16 * CGFloat(node.fanIn) / CGFloat(maxFanIn)
                    Circle()
                        .fill(GraphView.color(for: node.group, among: groups))
                        .overlay(Circle().stroke(hoveredPath == node.id ? Color.primary : Color.clear, lineWidth: 2))
                        .frame(width: diameter, height: diameter)
                        .position(position)
                        .help("\(node.id)\nimported by \(node.fanIn) · imports \(node.fanOut)")
                        .onHover { inside in
                            hoveredPath = inside ? node.id : (hoveredPath == node.id ? nil : hoveredPath)
                        }
                        .onTapGesture {
                            appState.selectedFilePath = node.id
                            appState.centerTab = .code
                        }
                    if nodes.count <= 60 || hoveredPath == node.id {
                        Text((node.id as NSString).lastPathComponent)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .position(labelPosition(position, center: center))
                            .allowsHitTesting(false)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(groups, id: \.self) { group in
                    HStack(spacing: 5) {
                        Circle().fill(GraphView.color(for: group, among: groups)).frame(width: 8, height: 8)
                        Text(group).font(.caption2)
                    }
                }
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func labelPosition(_ point: CGPoint, center: CGPoint) -> CGPoint {
        let dx = point.x - center.x
        let dy = point.y - center.y
        let length = max(1, sqrt(dx * dx + dy * dy))
        return CGPoint(x: point.x + dx / length * 22, y: point.y + dy / length * 22)
    }

    static func color(for group: String, among groups: [String]) -> Color {
        let index = groups.firstIndex(of: group) ?? 0
        let hue = Double(index) / Double(max(groups.count, 1))
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }
}
