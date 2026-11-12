import AppKit
import UniformTypeIdentifiers

/// Only destination presentation crosses the SwiftUI/AppKit boundary. NSDocument
/// still owns the file URL, dirty state, coordinated writes, and subsequent saves.
@MainActor
enum ProjectSaveCoordinator {
    static func save(window: NSWindow?, saveAs: Bool, completion: @escaping (Error?) -> Void) {
        guard let window, let document = NSDocumentController.shared.document(for: window) else {
            completion(CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The document window is not ready to save. Please try again."]))
            return
        }
        var destination = document.fileURL
        if saveAs || destination == nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.magnusVector]
            panel.canCreateDirectories = true
            panel.title = "Save Editable Project"
            panel.message = "Keep every object and layer in a Magdobe project."
            panel.nameFieldStringValue = destination?.lastPathComponent ?? "Artwork.mvector"
            panel.directoryURL = destination?.deletingLastPathComponent() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            guard panel.runModal() == .OK, let url = panel.url else { completion(nil); return }
            destination = url
        }
        guard let destination else { completion(CocoaError(.fileWriteUnknown)); return }
        document.save(to: destination, ofType: document.fileType ?? UTType.magnusVector.identifier,
                      for: saveAs ? .saveAsOperation : .saveOperation, completionHandler: completion)
    }
}
