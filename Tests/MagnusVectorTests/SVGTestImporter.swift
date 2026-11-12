import Foundation
import AppKit
@testable import MagnusVector

/// Independent, deliberately narrow SVG reader for export→import regression checks.
/// Reads standard geometry, paint and ordering. This is not a general-purpose SVG import UI.
/// Only text-box dimensions and Magdobe's non-standard lock state use extra attributes.
enum SVGTestImporter {
    enum Failure: Error { case unsupported(String) }
    static func read(_ doc: XMLDocument) throws -> VectorProject {
        guard let root = doc.rootElement(), let box = root.attribute(forName: "viewBox")?.stringValue else { throw Failure.unsupported("Missing viewport") }
        let dimensions = try numbers(box)
        guard dimensions.count == 4 else { throw Failure.unsupported("Bad viewport") }
        var project = VectorProject(width: dimensions[2], height: dimensions[3])
        let elements = try doc.nodes(forXPath: "//*[starts-with(@id, 'object_')]").compactMap { $0 as? XMLElement }
        for object in elements {
            var e = object
            if object.localName == "g" {
                let paints = (object.children ?? []).compactMap { $0 as? XMLElement }.filter { ["path","rect","ellipse"].contains($0.localName ?? "") }
                guard paints.count == 2, paints[0].localName == paints[1].localName else { throw Failure.unsupported("Unrecognized object group") }
                for key in ["d","x","y","width","height","cx","cy","rx","ry","opacity"] {
                    guard paints[0].attribute(forName: key)?.stringValue == paints[1].attribute(forName: key)?.stringValue else { throw Failure.unsupported("Paint geometry differs") }
                }
                e = paints[0].copy() as! XMLElement
                for key in ["stroke","stroke-opacity","stroke-width","stroke-linecap","stroke-linejoin"] {
                    e.removeAttribute(forName: key)
                    if let a = paints[1].attribute(forName: key) { e.addAttribute(a.copy() as! XMLNode) }
                }
                for key in ["id","data-name","display","data-magdobe-locked"] {
                    e.removeAttribute(forName: key)
                    if let a = object.attribute(forName: key) { e.addAttribute(a.copy() as! XMLNode) }
                }
            }
            func value(_ key: String) -> String? { e.attribute(forName: key)?.stringValue }
            func n(_ key: String, _ fallback: Double = 0) throws -> Double {
                guard let text = value(key) else { return fallback }
                guard let number = Double(text) else { throw Failure.unsupported("Invalid number: \(key)") }; return number
            }
            var shape: VectorShape
            switch e.localName {
            case "path": shape = try path(value("d") ?? "")
            case "rect": shape = VectorShape(name: "", kind: .rectangle, x: try n("x"), y: try n("y"), width: try n("width"), height: try n("height"))
            case "ellipse":
                let rx = try n("rx"), ry = try n("ry")
                shape = VectorShape(name: "", kind: .ellipse, x: try n("cx") - rx, y: try n("cy") - ry, width: rx * 2, height: ry * 2)
            case "text":
                let box = try numbers(value("data-magdobe-text-box") ?? "")
                guard box.count == 4 else { throw Failure.unsupported("Text box dimensions unavailable") }
                let text = try e.nodes(forXPath: "./*[local-name()='tspan']").map { $0.stringValue ?? "" }.joined()
                shape = VectorShape(name: "", kind: .text, x: box[0], y: box[1], width: box[2], height: box[3], stroke: nil, text: text, fontSize: try n("font-size"))
            default: throw Failure.unsupported(e.name ?? "Unknown element")
            }
            guard let id = value("id"), let uuid = UUID(uuidString: String(id.dropFirst("object_".count))) else { throw Failure.unsupported("Missing stable ID") }
            shape.id = uuid; shape.name = value("data-name") ?? ""
            shape.fill = try color(value("fill"), opacity: n("fill-opacity",1))
            shape.stroke = try color(value("stroke"), opacity: n("stroke-opacity",1))
            shape.strokeWidth = try n("stroke-width", shape.kind == .text ? 1 : 0)
            shape.opacity = try n("opacity",1); shape.visible = value("display") != "none"
            shape.locked = value("data-magdobe-locked") == "true"
            project.shapes.append(shape)
        }
        return try project.validated()
    }
    static func numbers(_ text: String) throws -> [Double] {
        try text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map {
            guard let n = Double($0) else { throw Failure.unsupported("Invalid number") }; return n
        }
    }
    static func color(_ text: String?, opacity: Double) throws -> VectorColor? {
        guard let text, text != "none" else { return nil }
        guard text.hasPrefix("rgb("), text.hasSuffix(")") else { throw Failure.unsupported("Unsupported paint") }
        let channels = text.dropFirst(4).dropLast().split(separator: ",")
        guard channels.count == 3 else { throw Failure.unsupported("Invalid color") }
        let values = try channels.map { token -> Double in
            guard token.hasSuffix("%"), let value = Double(token.dropLast()) else { throw Failure.unsupported("Invalid channel") }
            return value / 100
        }
        return VectorColor(red: values[0], green: values[1], blue: values[2], alpha: opacity)
    }
    static func path(_ d: String) throws -> VectorShape {
        let tokens = d.split(whereSeparator: \.isWhitespace).map(String.init)
        var i = 0, contours: [[Anchor]] = [], anchors: [Anchor] = [], allClosed = true
        func point() throws -> VectorPoint {
            guard i + 1 < tokens.count, let x = Double(tokens[i]), let y = Double(tokens[i+1]) else { throw Failure.unsupported("Invalid path coordinate") }
            i += 2; return VectorPoint(x,y)
        }
        func finish(_ closed: Bool) {
            guard !anchors.isEmpty else { return }
            if closed, anchors.count > 1, anchors.first?.point == anchors.last?.point {
                anchors[0].incoming = anchors.last?.incoming; anchors.removeLast()
            }
            contours.append(anchors); anchors = []; allClosed = allClosed && closed
        }
        while i < tokens.count {
            let command = tokens[i]; i += 1
            switch command {
            case "M": finish(false); anchors = [Anchor(try point().cg)]
            case "L": guard !anchors.isEmpty else { throw Failure.unsupported("Line before move") }; anchors.append(Anchor(try point().cg))
            case "C":
                guard !anchors.isEmpty else { throw Failure.unsupported("Curve before move") }
                let c1 = try point(), c2 = try point(), end = try point()
                anchors[anchors.count-1].outgoing = c1
                var a = Anchor(end.cg); a.incoming = c2; anchors.append(a)
            case "Q":
                guard let start = anchors.last?.point else { throw Failure.unsupported("Curve before move") }
                let c = try point(), end = try point()
                anchors[anchors.count-1].outgoing = VectorPoint(start.x + 2/3 * (c.x-start.x),start.y + 2/3 * (c.y-start.y))
                var a = Anchor(end.cg); a.incoming = VectorPoint(end.x + 2/3 * (c.x-end.x),end.y + 2/3 * (c.y-end.y)); anchors.append(a)
            case "Z": finish(true)
            default: throw Failure.unsupported("Unsupported command \(command)")
            }
        }
        finish(false)
        var shape = VectorShape(name: "", kind: .path, width: 0, height: 0)
        shape.contours = contours; shape.closed = allClosed && !contours.isEmpty
        return shape
    }
}
