import AppKit
import SwiftUI

struct VectorColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    static let ink = VectorColor(red: 0.09, green: 0.11, blue: 0.16)
    static let violet = VectorColor(red: 0.43, green: 0.32, blue: 0.96)
    static let paper = VectorColor(red: 1, green: 1, blue: 1)
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(nsColor: nsColor) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int(max(0, min(1, red)) * 255), Int(max(0, min(1, green)) * 255), Int(max(0, min(1, blue)) * 255))
    }
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: Color) {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

struct VectorPoint: Codable, Equatable {
    var x: Double
    var y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    var cg: CGPoint { CGPoint(x: x, y: y) }
    func offset(_ delta: CGSize) -> VectorPoint { VectorPoint(x + delta.width, y + delta.height) }
}

struct Anchor: Codable, Equatable, Identifiable {
    var id = UUID()
    var point: VectorPoint
    var incoming: VectorPoint?
    var outgoing: VectorPoint?
    init(_ point: CGPoint) { self.point = VectorPoint(point) }
    mutating func translate(_ delta: CGSize) {
        point = point.offset(delta); incoming = incoming?.offset(delta); outgoing = outgoing?.offset(delta)
    }
}

enum ShapeKind: String, Codable { case rectangle, ellipse, path, text }

struct VectorShape: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var kind: ShapeKind
    var x: Double = 0
    var y: Double = 0
    var width: Double = 100
    var height: Double = 100
    var anchors: [Anchor] = []
    var closed = false
    var fill: VectorColor? = .violet
    var stroke: VectorColor? = .ink
    var strokeWidth: Double = 1
    var opacity: Double = 1
    var visible = true
    var locked = false
    var text = "Type something"
    var fontSize: Double = 48
    // Additional closed contours share the primary contour's fill and winding rule.
    var subpaths: [[Anchor]]? = nil
    var contours: [[Anchor]] {
        get { [anchors] + (subpaths ?? []) }
        set { anchors = newValue.first ?? []; subpaths = newValue.count > 1 ? Array(newValue.dropFirst()) : nil }
    }

    var bounds: CGRect {
        if kind == .path {
            let rect = cgPath.boundingBoxOfPath
            return rect.isNull ? .zero : rect
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
    var cgPath: CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle: path.addRect(CGRect(x: x, y: y, width: width, height: height))
        case .ellipse: path.addEllipse(in: CGRect(x: x, y: y, width: width, height: height))
        case .text: path.addRect(CGRect(x: x, y: y, width: width, height: height))
        case .path:
            for contour in contours {
                guard let first = contour.first else { continue }
                path.move(to: first.point.cg)
                for i in 1..<contour.count { appendSegment(path, from: contour[i - 1], to: contour[i]) }
                if closed, let last = contour.last, contour.count > 1 {
                    appendSegment(path, from: last, to: first)
                    path.closeSubpath()
                }
            }
        }
        return path
    }
    private func appendSegment(_ path: CGMutablePath, from a: Anchor, to b: Anchor) {
        if a.outgoing != nil || b.incoming != nil {
            path.addCurve(to: b.point.cg, control1: (a.outgoing ?? a.point).cg, control2: (b.incoming ?? b.point).cg)
        } else { path.addLine(to: b.point.cg) }
    }
    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if kind == .text { return bounds.contains(point) }
        if fill != nil, cgPath.contains(point) { return true }
        return cgPath.copy(strokingWithWidth: max(strokeWidth, tolerance * 2), lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }
    mutating func translate(_ delta: CGSize) {
        x += delta.width; y += delta.height
        var updated = contours
        for c in updated.indices { for i in updated[c].indices { updated[c][i].translate(delta) } }
        contours = updated
    }
    mutating func resize(to rect: CGRect) {
        let old = bounds
        if kind == .path {
            let sx = old.width > 0.001 ? rect.width / old.width : 1
            let sy = old.height > 0.001 ? rect.height / old.height : 1
            func map(_ p: VectorPoint) -> VectorPoint {
                VectorPoint(rect.minX + (p.x - old.minX) * sx, rect.minY + (p.y - old.minY) * sy)
            }
            contours = contours.map { contour in contour.map { original in
                var a = original
                a.point = map(a.point); a.incoming = a.incoming.map(map); a.outgoing = a.outgoing.map(map)
                return a
            } }
        } else { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    }
    mutating func convertToPath() {
        guard kind == .rectangle || kind == .ellipse else { return }
        let r = bounds
        if kind == .rectangle {
            anchors = [Anchor(CGPoint(x: r.minX, y: r.minY)), Anchor(CGPoint(x: r.maxX, y: r.minY)), Anchor(CGPoint(x: r.maxX, y: r.maxY)), Anchor(CGPoint(x: r.minX, y: r.maxY))]
        } else {
            let k = 0.5522847498307936
            anchors = [Anchor(CGPoint(x: r.midX, y: r.minY)), Anchor(CGPoint(x: r.maxX, y: r.midY)), Anchor(CGPoint(x: r.midX, y: r.maxY)), Anchor(CGPoint(x: r.minX, y: r.midY))]
            let dx = r.width * k / 2, dy = r.height * k / 2
            anchors[0].incoming = VectorPoint(r.midX - dx, r.minY); anchors[0].outgoing = VectorPoint(r.midX + dx, r.minY)
            anchors[1].incoming = VectorPoint(r.maxX, r.midY - dy); anchors[1].outgoing = VectorPoint(r.maxX, r.midY + dy)
            anchors[2].incoming = VectorPoint(r.midX + dx, r.maxY); anchors[2].outgoing = VectorPoint(r.midX - dx, r.maxY)
            anchors[3].incoming = VectorPoint(r.minX, r.midY + dy); anchors[3].outgoing = VectorPoint(r.minX, r.midY - dy)
        }
        kind = .path; closed = true
    }
}

struct VectorProject: Codable, Equatable {
    var version = 1
    var width: Double = 1000
    var height: Double = 800
    var shapes: [VectorShape] = []
    var hierarchy: [VectorNode]? = nil

    func validated() throws -> VectorProject {
        guard version == 1 || version == 2 else { throw ValidationError.unsupportedVersion }
        guard width.isFinite, height.isFinite, (1...100_000).contains(width), (1...100_000).contains(height), shapes.count <= 100_000 else { throw ValidationError.invalidGeometry }
        guard Set(shapes.map(\.id)).count == shapes.count else { throw ValidationError.invalidGeometry }
        func valid(_ n: Double) -> Bool { n.isFinite && abs(n) <= 10_000_000 }
        func validPoint(_ point: VectorPoint) -> Bool { valid(point.x) && valid(point.y) }
        for s in shapes {
            let colors = [s.fill, s.stroke].compactMap { $0 }
            guard [s.x, s.y, s.width, s.height, s.strokeWidth, s.opacity, s.fontSize].allSatisfy(valid),
                  s.width >= 0, s.height >= 0, s.strokeWidth >= 0, (0...1).contains(s.opacity), s.fontSize > 0,
                  colors.allSatisfy({ [$0.red, $0.green, $0.blue, $0.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }) else { throw ValidationError.invalidGeometry }
            // Validate contours in place instead of allocating a second array of every coordinate.
            for contour in s.contours { for anchor in contour {
                guard validPoint(anchor.point), anchor.incoming.map(validPoint) ?? true,
                      anchor.outgoing.map(validPoint) ?? true else { throw ValidationError.invalidGeometry }
            } }
        }
        try validateHierarchy()
        return self
    }
    enum ValidationError: LocalizedError {
        case unsupportedVersion, invalidGeometry, invalidHierarchy
        var errorDescription: String? { switch self {
            case .unsupportedVersion: return "This document uses an unsupported version."
            case .invalidGeometry: return "This document contains invalid vector geometry."
            case .invalidHierarchy: return "This document contains an invalid layer hierarchy."
            } }
    }
}
