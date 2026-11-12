import AppKit
import CoreText

struct SVGExportOptions: Equatable {
    var preserveEditableLayers = true
    var convertTextToOutlines = false
    // Only removes formatting whitespace. Never rounds coordinates or merges objects.
    var optimize = false
    var entireArtboard = true
}

enum SVGExportError: LocalizedError {
    case invalidXMLText(String)
    case glyphHasNoOutline(String)
    case emptyDrawing
    var errorDescription: String? {
        switch self {
        case .invalidXMLText(let field): return "The \(field) contains a control character that XML cannot represent. Remove that character and export again."
        case .glyphHasNoOutline(let text): return "A glyph in “\(text.prefix(60))” has no vector outline (for example, a color emoji). Turn off Convert text to outlines or replace that character. No artwork was rasterized."
        case .emptyDrawing: return "There is no visible artwork to fit. Choose Export entire artboard."
        }
    }
}

/// SVG 1.1 geometry, without embedded bitmaps or an application-specific artwork payload.
/// The production file path streams one object at a time to an atomic replacement file.
/// `data` uses the identical serializer for clipboard use and automated validation.
enum SVGExporter {
    static func number(_ n: Double) -> String { n == 0 ? "0" : String(n) }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\t", with: "&#9;")
    }
    private static func validateXML(_ text: String, field: String) throws {
        guard text.unicodeScalars.allSatisfy({ s in
            s.value == 9 || s.value == 10 || s.value == 13 || (0x20...0xD7FF).contains(s.value) || (0xE000...0xFFFD).contains(s.value) || (0x10000...0x10FFFF).contains(s.value)
        }) else { throw SVGExportError.invalidXMLText(field) }
    }
    static func color(_ c: VectorColor) -> String { "rgb(\(number(c.red * 100))%,\(number(c.green * 100))%,\(number(c.blue * 100))%)" }
    static func objectID(_ s: VectorShape) -> String { "object_" + s.id.uuidString.lowercased() }

    static func data(_ project: VectorProject, options: SVGExportOptions = .init()) throws -> Data {
        var data = Data()
        try serialize(project, options: options, emit: { data.append(contentsOf: $0.utf8) })
        return data
    }
    static func write(_ project: VectorProject, to url: URL, options: SVGExportOptions = .init(), progress: @escaping (Int, Int) -> Void = { _, _ in }) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".magdobe-\(UUID().uuidString).svg.tmp")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try FileHandle(forWritingTo: temp)
        do {
            try serialize(project, options: options, emit: { try file.write(contentsOf: Data($0.utf8)) }, progress: progress)
            try Task.checkCancellation()
            try file.synchronize(); try file.close()
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else { try FileManager.default.moveItem(at: temp, to: url) }
        } catch { try? file.close(); throw error }
    }
    private static func viewport(_ project: VectorProject, options: SVGExportOptions) throws -> CGRect {
        if options.entireArtboard { return CGRect(x: 0, y: 0, width: project.width, height: project.height) }
        var bounds = CGRect.null
        for s in project.shapes where s.visible {
            var b = s.bounds
            if s.kind != .text, s.stroke != nil, s.strokeWidth > 0 {
                b = b.union(s.cgPath.copy(strokingWithWidth: s.strokeWidth, lineCap: .round, lineJoin: .round, miterLimit: 10).boundingBoxOfPath)
            }
            if !b.isNull { bounds = bounds.union(b) }
        }
        guard !bounds.isNull else { throw SVGExportError.emptyDrawing }
        return CGRect(x: bounds.minX, y: bounds.minY, width: max(1, bounds.width), height: max(1, bounds.height))
    }
    private static func serialize(_ project: VectorProject, options: SVGExportOptions, emit: (String) throws -> Void, progress: (Int, Int) -> Void = { _, _ in }) throws {
        _ = try project.validated()
        let box = try viewport(project, options: options)
        let newline = options.optimize ? "" : "\n"
        func line(_ s: String) throws { try emit(s + newline) }
        let viewBox = [box.minX, box.minY, box.width, box.height].map { number($0) }.joined(separator: " ")
        try line("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        // Explicit points match Core Graphics / PDF dimensions; viewBox retains document coordinates.
        try line("<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(number(box.width))pt\" height=\"\(number(box.height))pt\" viewBox=\"\(viewBox)\" preserveAspectRatio=\"xMinYMin meet\" overflow=\"hidden\">")
        try line("<title>Magdobe Illustrator artwork</title>")
        try line("<defs>")
        if options.entireArtboard {
            try line("<clipPath id=\"magdobe_artboard_clip\" clipPathUnits=\"userSpaceOnUse\"><rect x=\"0\" y=\"0\" width=\"\(number(project.width))\" height=\"\(number(project.height))\"/></clipPath>")
        }
        for s in project.shapes where s.kind == .text {
            try line("<clipPath id=\"text_clip_\(s.id.uuidString.lowercased())\" clipPathUnits=\"userSpaceOnUse\"><rect x=\"\(number(s.x))\" y=\"\(number(s.y))\" width=\"\(number(s.width))\" height=\"\(number(s.height))\"/></clipPath>")
        }
        try line("</defs>")
        try line("<g id=\"magdobe_artwork\"\(options.entireArtboard ? " clip-path=\"url(#magdobe_artboard_clip)\"" : "")>")
        progress(0, project.shapes.count)
        for (index, s) in project.shapes.enumerated() {
            try Task.checkCancellation()
            try validateXML(s.name, field: "object name")
            if s.kind == .text { try validateXML(s.text, field: "text object") }
            let name = escape(s.name), id = objectID(s)
            if options.preserveEditableLayers {
                try line("<g id=\"layer_\(s.id.uuidString.lowercased())\" data-name=\"\(name)\"><title>\(name)</title>")
            }
            // Named native objects retain order, visibility and IDs even when group wrappers are off.
            let identity = "id=\"\(id)\" data-name=\"\(name)\"\(s.locked ? " data-magdobe-locked=\"true\"" : "")\(s.visible ? "" : " display=\"none\"")"
            let fill = s.kind == .text ? (s.fill ?? .ink) : s.fill
            var appearance = "fill=\"\(fill.map(color) ?? "none")\" fill-opacity=\"\(number(fill?.alpha ?? 1))\" opacity=\"\(number(s.opacity))\" fill-rule=\"nonzero\""
            if s.kind != .text {
                appearance += " stroke=\"\(s.stroke.map(color) ?? "none")\" stroke-opacity=\"\(number(s.stroke?.alpha ?? 1))\" stroke-width=\"\(number(s.strokeWidth))\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-miterlimit=\"10\""
            }
            let title = "<title>\(name)</title>"
            if s.kind != .text, s.fill != nil, s.stroke != nil, s.strokeWidth > 0, s.opacity < 1 {
                // Core Graphics applies global alpha to each paint operation separately. A single SVG
                // element's opacity composites fill+stroke together, which changes their overlap.
                // Keep the two native paint operations in one editable object group for exact fidelity.
                try line("<g \(identity) data-magdobe-paints=\"separate\">\(title)")
                let fillPaint = "fill=\"\(s.fill.map(color) ?? "none")\" fill-opacity=\"\(number(s.fill?.alpha ?? 1))\" opacity=\"\(number(s.opacity))\" fill-rule=\"nonzero\" stroke=\"none\""
                let strokePaint = "fill=\"none\" stroke=\"\(s.stroke.map(color) ?? "none")\" stroke-opacity=\"\(number(s.stroke?.alpha ?? 1))\" stroke-width=\"\(number(s.strokeWidth))\" opacity=\"\(number(s.opacity))\" stroke-linecap=\"round\" stroke-linejoin=\"round\" stroke-miterlimit=\"10\""
                try line(geometry(s, identity: "id=\"paint_fill_\(s.id.uuidString.lowercased())\"", appearance: fillPaint, title: ""))
                try line(geometry(s, identity: "id=\"paint_stroke_\(s.id.uuidString.lowercased())\"", appearance: strokePaint, title: ""))
                try line("</g>")
            } else { switch s.kind {
            case .rectangle, .ellipse, .path:
                try line(geometry(s, identity: identity, appearance: appearance, title: title))
            case .text:
                let layout = SVGTextLayout(s)
                let clipping = "clip-path=\"url(#text_clip_\(s.id.uuidString.lowercased()))\""
                if options.convertTextToOutlines {
                    let path = try layout.outline()
                    try line("<path \(identity) d=\"\(pathData(path))\" \(appearance) \(clipping)>\(title)</path>")
                } else {
                    try line("<text \(identity) \(appearance) \(clipping) font-size=\"\(number(s.fontSize))\" font-family=\"&apos;\(escape(layout.fontFamily))&apos;, &apos;Helvetica Neue&apos;, Helvetica, Arial, sans-serif\" xml:space=\"preserve\" data-magdobe-text-box=\"\([s.x,s.y,s.width,s.height].map(number).joined(separator: " "))\">")
                    try line(title)
                    for fragment in layout.lines {
                        // Explicit baselines preserve native word wrapping instead of leaving it to SVG viewers.
                        try emit("<tspan x=\"\(number(fragment.origin.x))\" y=\"\(number(fragment.origin.y))\">\(escape(fragment.text))</tspan>")
                    }
                    try line("</text>")
                }
            }
            }
            if options.preserveEditableLayers { try line("</g>") }
            if (index + 1) % 32 == 0 || index + 1 == project.shapes.count { progress(index + 1, project.shapes.count) }
        }
        try line("</g></svg>")
    }
    private static func geometry(_ s: VectorShape, identity: String, appearance: String, title: String) -> String {
        switch s.kind {
        case .rectangle:
            return "<rect \(identity) x=\"\(number(s.x))\" y=\"\(number(s.y))\" width=\"\(number(s.width))\" height=\"\(number(s.height))\" \(appearance)>\(title)</rect>"
        case .ellipse:
            return "<ellipse \(identity) cx=\"\(number(s.x + s.width / 2))\" cy=\"\(number(s.y + s.height / 2))\" rx=\"\(number(s.width / 2))\" ry=\"\(number(s.height / 2))\" \(appearance)>\(title)</ellipse>"
        case .path:
            return "<path \(identity) d=\"\(pathData(s))\" \(appearance)>\(title)</path>"
        case .text: return ""
        }
    }
    static func pathData(_ shape: VectorShape) -> String {
        var result = ""
        func point(_ p: VectorPoint) -> String { "\(number(p.x)) \(number(p.y))" }
        func segment(_ a: Anchor, _ b: Anchor) -> String {
            if a.outgoing != nil || b.incoming != nil { return "C \(point(a.outgoing ?? a.point)) \(point(b.incoming ?? b.point)) \(point(b.point))" }
            return "L \(point(b.point))"
        }
        for anchors in shape.contours {
            guard let first = anchors.first else { continue }
            if !result.isEmpty { result += " " }
            result += "M \(point(first.point))"
            for i in anchors.indices.dropFirst() { result += " " + segment(anchors[i-1], anchors[i]) }
            if shape.closed, anchors.count > 1, let last = anchors.last { result += " " + segment(last, first) + " Z" }
        }
        return result
    }
    static func pathData(_ path: CGPath) -> String {
        var result = ""
        func pair(_ p: CGPoint) -> String { "\(number(p.x)) \(number(p.y))" }
        path.applyWithBlock { ptr in
            let e = ptr.pointee
            if !result.isEmpty { result += " " }
            switch e.type {
            case .moveToPoint: result += "M " + pair(e.points[0])
            case .addLineToPoint: result += "L " + pair(e.points[0])
            case .addQuadCurveToPoint: result += "Q " + pair(e.points[0]) + " " + pair(e.points[1])
            case .addCurveToPoint: result += "C " + pair(e.points[0]) + " " + pair(e.points[1]) + " " + pair(e.points[2])
            case .closeSubpath: result += "Z"
            @unknown default: break
            }
        }
        return result
    }
}

/// Isolated TextKit objects keep layout work off the main thread. Core Text supplies actual
/// fallback-font glyph outlines, never an image fallback. Baselines use the native font metrics.
private struct SVGTextLayout {
    struct Line { var text: String; var origin: CGPoint; var attributed: NSAttributedString }
    var lines: [Line] = []
    let fontFamily: String
    let source: String
    init(_ shape: VectorShape) {
        source = shape.text
        let font = NSFont.systemFont(ofSize: shape.fontSize, weight: .regular)
        fontFamily = font.familyName ?? font.fontName
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: shape.text, attributes: [.font: font, .paragraphStyle: style])
        let manager = NSLayoutManager(); manager.usesFontLeading = true
        let container = NSTextContainer(containerSize: NSSize(width: shape.width, height: .greatestFiniteMagnitude)); container.lineFragmentPadding = 0
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let range = manager.glyphRange(for: container)
        var fragments: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: range) { rect, _, _, glyphs, _ in
            guard glyphs.length > 0 else { return }
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let attributed = storage.attributedSubstring(from: chars)
            let location = manager.location(forGlyphAt: glyphs.location)
            fragments.append(Line(text: attributed.string, origin: CGPoint(x: shape.x + rect.minX, y: shape.y + rect.minY + location.y), attributed: attributed))
        }
        lines = fragments
    }
    func outline() throws -> CGPath {
        let path = CGMutablePath()
        for line in lines {
            let ctLine = CTLineCreateWithAttributedString(line.attributed)
            for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let font = attrs[kCTFontAttributeName] else { throw SVGExportError.glyphHasNoOutline(source) }
                let ctFont = font as! CTFont
                let n = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
                var indices = [CFIndex](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                for i in 0..<n {
                    if let glyph = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) {
                        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: line.origin.x + positions[i].x, ty: line.origin.y - positions[i].y)
                        if let mapped = glyph.copy(using: &transform) { path.addPath(mapped) }
                    } else {
                        let character = (line.text as NSString).character(at: max(0, min(indices[i], (line.text as NSString).length - 1)))
                        guard let scalar = UnicodeScalar(character), CharacterSet.whitespacesAndNewlines.contains(scalar) else { throw SVGExportError.glyphHasNoOutline(source) }
                    }
                }
            }
        }
        return path
    }
}
