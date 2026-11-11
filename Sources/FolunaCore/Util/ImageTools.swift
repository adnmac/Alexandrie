import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageTools {
    /// Type MIME d'après la signature binaire.
    static func mimeType(_ b: [UInt8]) -> String? {
        if b.count >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return "image/png" }
        if b.hasPrefix("GIF8") { return "image/gif" }
        if b.hasPrefix("BM") { return "image/bmp" }
        return nil
    }

    static func fileExtension(forMime mime: String) -> String {
        switch mime {
        case "image/jpeg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/bmp": "bmp"
        case "image/svg+xml": "svg"
        default: "bin"
        }
    }

    static func jpegData(_ image: NSImage, quality: Double = 0.85) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Redimensionne (sans agrandir) et encode en JPEG.
    public static func jpeg(_ data: Data, maxPixelSize: Int, quality: Double = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
