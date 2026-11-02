import Foundation

/// Rapprochement entre les fichiers trouvés sur disque et l'index existant, lors d'un rescan.
public enum LibraryMerge {
    public struct Plan: Sendable {
        /// Livres repris tels quels (chemin mis à jour s'ils ont été déplacés ou renommés).
        public var kept: [Book]
        /// Fichiers à relire, avec le livre indexé qu'ils remplacent s'il existe.
        public var changed: [(file: ScannedFile, previous: Book?)]
    }

    /// Un fichier est retrouvé par son chemin, sinon par son empreinte parmi les livres disparus :
    /// un livre déplacé ou renommé garde ainsi ses retouches.
    public static func plan(files: [ScannedFile], known: [Book], importsPath: String) -> Plan {
        let byPath = Dictionary(known.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let presentPaths = Set(files.map(\.url.path))
        var vanished = Dictionary(grouping: known.filter { !presentPaths.contains($0.path) }, by: \.fingerprint)

        var plan = Plan(kept: [], changed: [])
        for f in files {
            var previous = byPath[f.url.path]
            if previous == nil {
                let fingerprint = FolderScanner.fingerprint(f.url, size: f.size)
                if var candidates = vanished[fingerprint], !candidates.isEmpty {
                    var moved = candidates.removeFirst()
                    vanished[fingerprint] = candidates
                    moved.path = f.url.path
                    moved.isImported = f.url.path.hasPrefix(importsPath)
                    // Même contenu : seule la date de modification peut différer (copie, synchronisation).
                    moved.modifiedAt = f.modifiedAt
                    previous = moved
                }
            }
            if var b = previous, b.fileSize == f.size,
               abs(b.modifiedAt.timeIntervalSince(f.modifiedAt)) < 1,
               b.metadataVersion == Book.currentMetadataVersion {
                // La date d'ajout suit le fichier (corrige aussi les livres datés de leur indexation).
                b.addedAt = f.addedAt
                plan.kept.append(b)
            } else {
                plan.changed.append((f, previous))
            }
        }
        return plan
    }

    /// Fichier modifié ou index plus ancien : les retouches faites dans l'app restent prioritaires.
    public static func carryOver(from previous: Book, to book: inout Book) {
        book.title = previous.title
        book.authors = previous.authors
        book.publisher = previous.publisher ?? book.publisher
        book.language = previous.language ?? book.language
        book.summary = previous.summary ?? book.summary
        book.publishedDate = previous.publishedDate ?? book.publishedDate
        book.isbn = previous.isbn ?? book.isbn
        book.genre = previous.genre ?? book.genre
        book.catalogRecord = previous.catalogRecord
        book.catalogCheckedAt = previous.catalogCheckedAt
        book.catalogDismissed = previous.catalogDismissed
        book.tags = previous.tags
        book.asin = previous.asin
        book.lastSentAt = previous.lastSentAt
        book.sentFilename = previous.sentFilename
        book.pendingSendAt = previous.pendingSendAt
        book.trashedAt = previous.trashedAt
        book.shelves = previous.shelves
    }
}
