import SwiftUI

struct BrushControls: View {
    @ObservedObject var session: EditorSession
    private var pencil: Bool { session.tool == .pencil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pencil ? "PENCIL" : "BRUSH").font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
            if !pencil {
                Picker("Preset", selection: $session.brushSettings.preset) {
                    ForEach(BrushPreset.allCases) { Text($0.rawValue).tag($0) }
                }.help("Round, tapered ink, or an angled calligraphy nib")
            }
            BrushPreview(settings: session.brushSettings, pencil: pencil, pencilSize: session.pencilSize, color: session.brushColor)
                .frame(height: 52).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Stroke preview")
            ColorPicker("Color", selection: Binding(get: { session.brushColor.color }, set: { session.brushColor = VectorColor($0) }), supportsOpacity: false)
                .help("Color for new freehand strokes")
            NumericField(label: "Size", value: pencil ? session.pencilSize : session.brushSettings.size) { value in
                guard value.isFinite else { return }
                let size = min(300, max(1, value))
                if pencil { session.pencilSize = size } else { session.brushSettings.size = size }
            }.help("Width in artboard points; use [ and ] on the canvas")
            VStack(alignment: .leading, spacing: 3) {
                Text("Smoothing  \(Int(session.brushSettings.smoothing * 100))%").font(.system(size: 11)).monospacedDigit()
                Slider(value: $session.brushSettings.smoothing, in: 0...1).accessibilityLabel("Stroke smoothing")
                    .help("Higher values reduce hand jitter and use fewer curve anchors")
            }
            NumericField(label: "Opacity %", value: session.brushSettings.opacity * 100) { value in
                if value.isFinite { session.brushSettings.opacity = min(1, max(0, value / 100)) }
            }.help("Opacity of the next complete stroke; overlaps within one stroke do not darken")
            if !pencil {
                Toggle("Tablet pressure", isOn: $session.brushSettings.usePressure).font(.system(size: 12))
                    .help("Vary width with a pressure-sensitive tablet. Mouse and trackpad use a steady width.")
                if session.brushSettings.preset == .calligraphy {
                    NumericField(label: "Angle °", value: session.brushSettings.angle) { if $0.isFinite { session.brushSettings.angle = min(90, max(-90, $0)) } }
                        .help("Angle of the calligraphy nib")
                    NumericField(label: "Roundness %", value: session.brushSettings.roundness * 100) { if $0.isFinite { session.brushSettings.roundness = min(1, max(0.1, $0 / 100)) } }
                        .help("10% makes a thin nib; 100% makes a circular nib")
                }
            }
            Text(pencil ? "Draw a curve, then reshape its anchors with Direct Selection (A)." : "Each stroke becomes an editable filled path. Use Direct Selection (A) to reshape its outline.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Settings apply to your next stroke.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct BrushPreview: View {
    var settings: BrushSettings
    var pencil: Bool
    var pencilSize: Double
    var color: VectorColor
    var body: some View {
        Canvas { context, size in
            var options = settings
            options.size = min(20, pencil ? pencilSize : settings.size); options.usePressure = false
            var stroke = FreehandStroke(pencil: pencil, settings: options, color: color)
            for i in 0...40 {
                let t = Double(i) / 40
                stroke.append(CGPoint(x: 18 + t * max(1, size.width - 36), y: size.height / 2 + sin(t * .pi * 2) * 9), pressure: nil)
            }
            context.opacity = options.opacity
            if pencil { context.stroke(Path(stroke.geometry()), with: .color(color.color), style: StrokeStyle(lineWidth: options.size, lineCap: .round, lineJoin: .round)) }
            else { context.fill(Path(stroke.geometry()), with: .color(color.color)) }
        }
    }
}
