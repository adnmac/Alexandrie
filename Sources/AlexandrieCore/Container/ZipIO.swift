import Foundation
import ZIPFoundation

/// Lecture d'une archive ZIP (EPUB) par chemin interne.
final class ZipReader {
    private let archive: Archive

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw BookError.unreadable("archive ZIP invalide")
        }
    }

    var paths: [String] {
        archive.map(\.path)
    }

    func contains(_ path: String) -> Bool {
        archive[path] != nil
    }

    func data(_ path: String) throws -> Data {
        guard let entry = archive[path] ?? caseInsensitiveEntry(path) else {
            throw BookError.unreadable("fichier absent de l'archive : \(path)")
        }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        return data
    }

    private func caseInsensitiveEntry(_ path: String) -> Entry? {
        let lower = path.lowercased()
        return archive.first { $0.path.lowercased() == lower }
    }
}

/// Écriture d'une archive ZIP ; le premier fichier ajouté est stocké sans compression
/// (exigence EPUB pour `mimetype`).
final class ZipWriter {
    private let archive: Archive
    private var isFirst = true

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        archive = try Archive(url: url, accessMode: .create)
    }

    func add(_ path: String, data: Data, compress: Bool = true) throws {
        let method: CompressionMethod = (compress && !isFirst) ? .deflate : .none
        isFirst = false
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count),
            compressionMethod: method,
            provider: { position, size in
                let start = Int(position)
                return data.subdata(in: start..<(start + size))
            })
    }
}
