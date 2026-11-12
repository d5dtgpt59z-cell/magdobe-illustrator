import AppKit

enum BrushPreset: String, CaseIterable, Identifiable {
    case round = "Round", ink = "Tapered Ink", calligraphy = "Calligraphy"
    var id: Self { self }
}

struct BrushSettings: Equatable {
    var preset: BrushPreset = .round
    var size = 18.0
    var smoothing = 0.5
    var opacity = 1.0
    var angle = -35.0
    var roundness = 0.25
    var usePressure = true

    var sanitized: Self {
        func clamp(_ n: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            n.isFinite ? min(range.upperBound, max(range.lowerBound, n)) : fallback
        }
        var result = self
        result.size = clamp(size, 1...300, 18)
        result.smoothing = clamp(smoothing, 0...1, 0.5)
        result.opacity = clamp(opacity, 0...1, 1)
        result.angle = clamp(angle, -90...90, -35)
        result.roundness = clamp(roundness, 0.1...1, 0.25)
        return result
    }
}

struct StrokeSample {
    var point: CGPoint
    // nil means mouse/trackpad: use a consistent full-width stroke.
    var pressure: Double?
}

/// A transient gesture, kept outside the document until mouse-up. There is no
/// raster backing and no new document format: completed marks are ordinary paths.
struct FreehandStroke {
    let pencil: Bool
    let settings: BrushSettings
    let color: VectorColor
    let parent: UUID?
    private(set) var samples: [StrokeSample] = []
    static let sampleLimit = 4096

    init(pencil: Bool, settings: BrushSettings, color: VectorColor, parent: UUID? = nil) {
        self.pencil = pencil; self.settings = settings.sanitized; self.color = color; self.parent = parent
    }

    mutating func append(_ point: CGPoint, pressure: Double?, minimumDistance: Double = 0.5) {
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1_000_000, abs(point.y) <= 1_000_000 else { return }
        let pressure = pressure.flatMap { $0.isFinite ? max(0.05, min(1, $0)) : nil }
        let sample = StrokeSample(point: point, pressure: pressure)
        if let last = samples.last, hypot(point.x - last.point.x, point.y - last.point.y) < max(0.01, minimumDistance) {
            // Stationary tablet pressure changes must affect a dot, without duplicate vertices.
            if samples.count == 1 { samples[0].pressure = pressure }
            return
        }
        if samples.count >= Self.sampleLimit {
            samples = samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil } + [samples.last!]
        }
        samples.append(sample)
    }

    func shape(normalize: Bool = true) -> VectorShape? {
        guard !samples.isEmpty else { return nil }
        let path = geometry(normalize: normalize)
        var result = VectorShape(name: pencil ? "Pencil" : "\(settings.preset.rawValue) Brush", kind: .path,
                                 width: 0, height: 0, fill: pencil && samples.count > 1 ? nil : color,
                                 stroke: pencil && samples.count > 1 ? color : nil,
                                 strokeWidth: pencil ? settings.size : 0, opacity: settings.opacity)
        result.closed = !pencil || samples.count == 1
        result.contours = Self.anchors(from: path)
        return result.anchors.isEmpty ? nil : result
    }

    func geometry(normalize: Bool = false) -> CGPath {
        let fitted = fittedSamples()
        guard let first = fitted.first else { return CGMutablePath() }
        if fitted.count == 1 {
            return nib(at: first.point, radius: settings.size / 2 * widthFactor(first, progress: 0.5))
        }
        let center = centerline(fitted)
        if pencil { return center.cgPath }
        let hasPressure = settings.usePressure && fitted.contains { $0.pressure != nil }
        if settings.preset != .ink && !hasPressure {
            // Stroke in circular-nib coordinates, then map back to an angled elliptical nib.
            var nibTransform = transform
            var inverse = nibTransform.inverted()
            let local = center.cgPath.copy(using: &inverse)!
            return local.copy(strokingWithWidth: settings.size, lineCap: .round, lineJoin: .round, miterLimit: 2).copy(using: &nibTransform)!
        }
        // Variable-width strokes sweep discs/ellipses and connecting quads. All
        // contours have the same winding, so overlaps are filled once, even at
        // partial opacity. Normalizing on commit removes internal edges for node editing.
        let points = flattened(center, samples: fitted)
        var lengths = [0.0]
        for i in 1..<points.count { lengths.append(lengths.last! + distance(points[i - 1].point, points[i].point)) }
        let total = max(lengths.last ?? 0, 0.001), path = CGMutablePath()
        var previous: (StrokeSample, Double)?
        for (i, sample) in points.enumerated() {
            let radius = settings.size / 2 * widthFactor(sample, progress: lengths[i] / total)
            path.addPath(nib(at: sample.point, radius: radius))
            if let (prior, priorRadius) = previous {
                let d = distance(prior.point, sample.point)
                if d > 0.0001 {
                    let normal = CGPoint(x: -(sample.point.y - prior.point.y) / d, y: (sample.point.x - prior.point.x) / d)
                    let offset = nibOffset(normal)
                    // Positive orientation matches CGPath's ellipse winding;
                    // reversing this would subtract discs from the connecting strip.
                    let corners = [add(prior.point, offset, priorRadius), add(prior.point, offset, -priorRadius),
                                   add(sample.point, offset, -radius), add(sample.point, offset, radius)]
                    path.move(to: corners[0]); corners.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
                }
            }
            previous = (sample, radius)
        }
        return normalize ? path.normalized(using: .winding) : path
    }

    private var transform: CGAffineTransform {
        settings.preset == .calligraphy && !pencil
            ? CGAffineTransform(rotationAngle: settings.angle * .pi / 180).scaledBy(x: 1, y: settings.roundness) : .identity
    }
    private func nib(at point: CGPoint, radius: Double) -> CGPath {
        var t = transform; t.tx = point.x; t.ty = point.y
        return CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: &t)
    }
    private func nibOffset(_ normal: CGPoint) -> CGPoint {
        let t = transform
        let nx = t.a * normal.x + t.b * normal.y, ny = t.c * normal.x + t.d * normal.y
        let length = max(hypot(nx, ny), 0.0001)
        return CGPoint(x: (t.a * nx + t.c * ny) / length, y: (t.b * nx + t.d * ny) / length)
    }
    private func widthFactor(_ sample: StrokeSample, progress: Double) -> Double {
        let pressure = settings.usePressure && !pencil ? sample.pressure ?? 1 : 1
        let taper = settings.preset == .ink && !pencil ? 0.12 + 0.88 * min(1, min(progress, 1 - progress) / 0.18) : 1
        return max(0.05, pressure) * taper
    }
    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private func add(_ p: CGPoint, _ v: CGPoint, _ scale: Double) -> CGPoint { CGPoint(x: p.x + v.x * scale, y: p.y + v.y * scale) }

    private func fittedSamples() -> [StrokeSample] {
        guard samples.count > 2 else { return samples }
        // Iterative Ramer-Douglas-Peucker with pressure deviation as a second
        // constraint. Endpoints and pressure peaks survive curve simplification.
        let tolerance = 0.15 + settings.smoothing * 2.5
        var keep: Set<Int> = [0, samples.count - 1], ranges = [(0, samples.count - 1)]
        while let (start, end) = ranges.popLast() {
            guard end > start + 1 else { continue }
            let a = samples[start], b = samples[end]
            let dx = b.point.x - a.point.x, dy = b.point.y - a.point.y, length2 = dx * dx + dy * dy
            var worst = tolerance, split: Int?
            for i in (start + 1)..<end {
                let p = samples[i]
                let t = length2 > 0 ? max(0, min(1, ((p.point.x - a.point.x) * dx + (p.point.y - a.point.y) * dy) / length2)) : 0
                var error = distance(p.point, CGPoint(x: a.point.x + t * dx, y: a.point.y + t * dy))
                if settings.usePressure && !pencil {
                    let expected = (a.pressure ?? 1) * (1 - t) + (b.pressure ?? 1) * t
                    error = max(error, abs((p.pressure ?? 1) - expected) * settings.size)
                }
                if error > worst { worst = error; split = i }
            }
            if let split { keep.insert(split); ranges.append((start, split)); ranges.append((split, end)) }
        }
        return keep.sorted().map { samples[$0] }
    }
    private func centerline(_ samples: [StrokeSample]) -> VectorShape {
        var shape = VectorShape(name: "Centerline", kind: .path, fill: nil)
        shape.anchors = samples.map { Anchor($0.point) }
        guard settings.smoothing > 0 else { return shape }
        for i in samples.indices {
            let p = samples[i].point, before = samples[max(0, i - 1)].point, after = samples[min(samples.count - 1, i + 1)].point
            let length = distance(before, after)
            guard length > 0.0001 else { continue }
            let tangent = CGPoint(x: (after.x - before.x) / length, y: (after.y - before.y) / length)
            if i > 0 { shape.anchors[i].incoming = VectorPoint(add(p, tangent, -distance(before, p) / 3)) }
            if i < samples.count - 1 { shape.anchors[i].outgoing = VectorPoint(add(p, tangent, distance(p, after) / 3)) }
        }
        return shape
    }
    private func flattened(_ center: VectorShape, samples: [StrokeSample]) -> [StrokeSample] {
        var result = [samples[0]]
        let spacing = max(0.75, min(4, settings.size / 4))
        for i in 1..<center.anchors.count {
            let a = center.anchors[i - 1], b = center.anchors[i]
            let p = a.point.cg, q = (a.outgoing ?? a.point).cg, r = (b.incoming ?? b.point).cg, s = b.point.cg
            let length = distance(p, q) + distance(q, r) + distance(r, s)
            // Bound extreme jumps while interpolating a continuous connecting quad.
            let perSegmentLimit = max(1, min(64, 8192 / max(1, center.anchors.count - 1)))
            let steps = max(1, min(perSegmentLimit, Int(ceil(length / spacing))))
            for step in 1...steps {
                let t = Double(step) / Double(steps), u = 1 - t
                let point = CGPoint(x: u*u*u*p.x + 3*u*u*t*q.x + 3*u*t*t*r.x + t*t*t*s.x,
                                    y: u*u*u*p.y + 3*u*u*t*q.y + 3*u*t*t*r.y + t*t*t*s.y)
                let pressure = (samples[i - 1].pressure ?? 1) * u + (samples[i].pressure ?? 1) * t
                result.append(StrokeSample(point: point, pressure: pressure))
            }
        }
        return result
    }

    static func anchors(from path: CGPath) -> [[Anchor]] {
        var contours: [[Anchor]] = [], current: [Anchor] = []
        func finish(closed: Bool = false) {
            if closed, current.count > 1, let first = current.first, let last = current.last,
               hypot(first.point.x - last.point.x, first.point.y - last.point.y) < 0.00001 {
                current[0].incoming = last.incoming; current.removeLast()
            }
            if !current.isEmpty { contours.append(current) }; current = []
        }
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint: finish(); current.append(Anchor(e.points[0]))
            case .addLineToPoint: current.append(Anchor(e.points[0]))
            case .addCurveToPoint:
                if !current.isEmpty { current[current.count - 1].outgoing = VectorPoint(e.points[0]) }
                var end = Anchor(e.points[2]); end.incoming = VectorPoint(e.points[1]); current.append(end)
            case .addQuadCurveToPoint:
                guard let start = current.last?.point.cg else { return }
                let control = e.points[0], end = e.points[1]
                current[current.count - 1].outgoing = VectorPoint(start.x + 2 / 3 * (control.x - start.x), start.y + 2 / 3 * (control.y - start.y))
                var anchor = Anchor(end); anchor.incoming = VectorPoint(end.x + 2 / 3 * (control.x - end.x), end.y + 2 / 3 * (control.y - end.y)); current.append(anchor)
            case .closeSubpath: finish(closed: true)
            @unknown default: break
            }
        }
        finish(); return contours
    }
}
