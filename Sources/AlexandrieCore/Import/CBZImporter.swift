import Foundation

/// Bande dessinée en archive ZIP (`.cbz`) : une image par page, dans l'ordre des noms (« page2 » avant
/// « page10 »). Informations de `ComicInfo.xml` s'il est là. Pages réduites à une taille de liseuse, en JPEG.
public enum CBZImporter: BookImporter {
    public static let id = "cbz"
    public static var formats: [BookFormat] { [.cbz] }
    public static var output: ImportOutput { .pages }
    public static let version = 1

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp"]

    public static func detect(_ header: Data) -> Bool {
        header.starts(with: [0x50, 0x4B, 0x03, 0x04])
    }

    /// Informations et couverture (première page) sans lire toutes les pages.
    public static func metadata(of url: URL) throws -> BookMetadata {
        let zip = try ZipReader(url: url)
        let pages = try pagePaths(zip)
        var meta = comicInfo(zip) ?? BookMetadata(title: url.deletingPathExtension().lastPathComponent)
        if meta.title.isEmpty { meta.title = url.deletingPathExtension().lastPathComponent }
        if let first = pages.first, let data = try? zip.data(first, limit: ImportLimits.maxEntrySize),
           ImportLimits.acceptsImage(data) {
            meta.coverData = ImageTools.jpeg(data, maxPixelSize: 1200)
        }
        return meta
    }

    public static func document(of url: URL) throws -> ImportedDocument {
        let zip = try ZipReader(url: url)
        let paths = try pagePaths(zip)
        var meta = comicInfo(zip) ?? BookMetadata(title: url.deletingPathExtension().lastPathComponent)
        if meta.title.isEmpty { meta.title = url.deletingPathExtension().lastPathComponent }
        var images: [ImportedDocument.Image] = []
        var chapters: [ImportedDocument.Chapter] = []
        for path in paths {
            // Une page illisible ou démesurée est sautée, pas tout l'album.
            guard let data = try? zip.data(path, limit: ImportLimits.maxEntrySize), ImportLimits.acceptsImage(data),
                  let jpeg = ImageTools.jpeg(data, maxPixelSize: ImportLimits.pageMaxPixelSize) else { continue }
            let name = String(format: "page%04d.jpg", images.count + 1)
            images.append(.init(name: name, mediaType: "image/jpeg", data: jpeg))
            chapters.append(.init(title: nil, body: "<div><img src=\"../Images/\(name)\" alt=\"\"/></div>", pageImage: name))
        }
        guard !images.isEmpty else { throw BookError.unreadable(String(localized: "aucune page lisible")) }
        return ImportedDocument(metadata: meta, chapters: chapters, images: images, cover: images.first?.name)
    }

    /// Images de l'archive, dans l'ordre de lecture ; dossiers cachés et `__MACOSX` ignorés.
    static func pagePaths(_ zip: ZipReader) throws -> [String] {
        let files = zip.files
        guard files.count <= ImportLimits.maxArchiveEntries,
              files.reduce(Int64(0), { $0 + $1.size }) <= ImportLimits.maxArchiveSize else { throw ImportLimits.tooLarge }
        let pages = files.map(\.path).filter { path in
            let parts = path.split(separator: "/")
            return !parts.contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
                && imageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        guard !pages.isEmpty else { throw BookError.unreadable(String(localized: "aucune image dans l'archive")) }
        return pages.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `ComicInfo.xml` (format de ComicRack, repris par la plupart des outils).
    static func comicInfo(_ zip: ZipReader) -> BookMetadata? {
        guard let path = zip.files.first(where: { ($0.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml" })?.path,
              let data = try? zip.data(path, limit: 1 << 20),
              let root = try? FB2Importer.safeXMLRoot(data) else { return nil }
        func field(_ name: String) -> String? { root.firstChild(named: name)?.textContent.nilIfEmpty }
        let series = field("Series")
        var title = field("Title") ?? series ?? ""
        if let series, let number = field("Number"), field("Title") == nil { title = "\(series) \(number)" }
        var meta = BookMetadata(title: title)
        meta.authors = (field("Writer") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        meta.summary = field("Summary")
        meta.publisher = field("Publisher")
        meta.language = field("LanguageISO")
        meta.publishedDate = field("Year")
        meta.series = series
        meta.seriesIndex = field("Number").flatMap(Double.init)
        return meta
    }
}
