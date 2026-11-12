import SwiftUI
import AppKit

enum PaperTexture {
    static let accent = Color(red: 0.73, green: 0.28, blue: 0.08)
    static let tile: NSImage = {
        let side = 256
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
        var seed: UInt64 = 0x4d4147444f4245
        let bytes = bitmap.bitmapData!
        for y in 0..<side { for x in 0..<side {
            seed = seed &* 6364136223846793005 &+ 1
            let grain = Int((seed >> 32) % 9) - 4
            let fiber = (y % 17 == 0 && x % 9 < 3) ? -3 : 0
            let i = (y * side + x) * 4
            bytes[i] = UInt8(clamping: 243 + grain + fiber)
            bytes[i + 1] = UInt8(clamping: 233 + grain + fiber)
            bytes[i + 2] = UInt8(clamping: 211 + grain + fiber)
            bytes[i + 3] = 255
        } }
        let image = NSImage(size: NSSize(width: side, height: side)); image.addRepresentation(bitmap); return image
    }()
    static var surface: some View { Image(nsImage: tile).resizable(resizingMode: .tile).accessibilityHidden(true) }
}
