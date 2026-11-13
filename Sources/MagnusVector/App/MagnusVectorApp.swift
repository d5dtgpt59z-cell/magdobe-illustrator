import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct MagnusVectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        DocumentGroup(newDocument: { VectorDocument() }) { file in
            ContentView(document: file.document)
        }
        .defaultSize(width: 1380, height: 900)
        .commands { EditorCommands() }
        Settings { ProviderSettingsView() }
    }
}

struct EditorCommands: Commands {
    @FocusedObject private var session: EditorSession?
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { session?.undo() }.keyboardShortcut("z").disabled(session?.canUndo != true)
            Button("Redo") { session?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(session?.canRedo != true)
        }
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { session?.duplicate() }.keyboardShortcut("d").disabled(session?.selection.isEmpty != false)
            Button("Delete") { session?.deleteSelection() }.disabled(session?.selection.isEmpty != false)
            Divider()
            Button("Select All") {
                if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.selectAll(nil); return }
                guard let session else { return }
                session.selectAll()
            }.keyboardShortcut("a")
            Button("Deselect") { session?.selection = [] }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { session?.saveProject() }.keyboardShortcut("s").disabled(session == nil || session?.savingProject == true)
            Button("Save As…") { session?.saveProject(saveAs: true) }.keyboardShortcut("s", modifiers: [.command, .shift, .option]).disabled(session == nil || session?.savingProject == true)
            Button("Duplicate Document") { NSApp.sendAction(#selector(NSDocument.duplicate(_:)), to: nil, from: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(session == nil)
        }
        CommandGroup(after: .saveItem) {
            Menu("Export") { ForEach(ExportFormat.allCases, id: \.self) { format in Button("\(format.rawValue.uppercased())…") { session?.export(format) } } }
            .disabled(session == nil)
        }
        CommandMenu("Artwork") {
            Button("Draw with AI…") { session?.showGeneration = true }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(session == nil)
            Divider()
            Button("Pencil") { session?.selectTool(.pencil) }.disabled(session == nil)
            Button("Brush") { session?.selectTool(.brush) }.disabled(session == nil)
        }
        CommandMenu("Object") {
            Button("Group") { session?.groupSelection() }.keyboardShortcut("g").disabled(session?.canGroup != true)
            Button("Ungroup") { session?.ungroupSelection() }.keyboardShortcut("g", modifiers: [.command, .option]).disabled(session?.canUngroup != true)
            Button("New Layer") { session?.newLayer() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(session == nil)
            Button("Edit Inside Group") { if let node = session?.selectedNode { session?.enterGroup(node.id) } }
                .disabled(session?.selectedNode?.kind != .group)
            Button("Exit Group") { session?.exitGroup() }.keyboardShortcut(.escape, modifiers: []).disabled(session?.isolatedGroupID == nil)
            Divider()
            Button("Convert to Path") { session?.modifySelection("Convert to Path") { $0.convertToPath() }; session?.selectTool(.node) }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(session?.selection.isEmpty != false)
            Divider()
            Button("Bring to Front") { session?.reorder(true) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Send to Back") { session?.reorder(false) }.keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Canvas") {
            Button("Fit Artboard") { session?.fit() }.keyboardShortcut("0")
            Button("Actual Size") { session?.zoom = 1; session?.pan = .zero }.keyboardShortcut("1")
            Button("Zoom In") { if let s = session { s.zoom = min(32, s.zoom * 1.25) } }.keyboardShortcut("+")
            Button("Zoom Out") { if let s = session { s.zoom = max(0.02, s.zoom / 1.25) } }.keyboardShortcut("-")
            Divider()
            Button("Toggle Grid") { session?.grid.toggle() }.keyboardShortcut("'", modifiers: .command)
        }
    }
}
