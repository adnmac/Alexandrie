import Foundation
import ImageIO

/// Garde-fous communs aux importeurs : un fichier démesuré ou piégé (archive qui se décompresse en
/// plusieurs gigaoctets, image de 50 000 pixels de côté…) est refusé comme illisible, sans bloquer l'app.
public enum ImportLimits {
    /// Fichier source.
    public static let maxFileSize: Int64 = 1 << 30            // 1 Go
    /// Texte décodé (TXT, FB2).
    public static let maxTextSize = 64 << 20                   // 64 Mo
    /// Entrées d'une archive.
    public static let maxArchiveEntries = 5_000
    /// Une entrée décompressée.
    public static let maxEntrySize = 200 << 20                 // 200 Mo
    /// Somme des entrées décompressées.
    public static let maxArchiveSize: Int64 = 2 << 30          // 2 Go
    /// Pixels d'une image (largeur × hauteur).
    public static let maxPixels = 120_000_000
    /// Taille du côté le plus long d'une page produite (bande dessinée) : assez pour une Kindle Scribe.
    public static let pageMaxPixelSize = 2_400

    static func checkFileSize(_ url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if size > maxFileSize { throw tooLarge }
    }

    static var tooLarge: BookError { .unreadable(String(localized: "fichier trop volumineux")) }

    /// Dimensions d'une image, lues dans son en-tête sans la décoder.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// Image lisible et de taille raisonnable.
    static func acceptsImage(_ data: Data) -> Bool {
        guard let size = pixelSize(of: data) else { return false }
        let (pixels, overflow) = size.width.multipliedReportingOverflow(by: size.height)
        return !overflow && pixels <= maxPixels
    }
}
