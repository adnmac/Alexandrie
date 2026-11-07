import CoreServices
import Foundation

/// Index du texte des livres (S-081), sur SearchKit : un document par livre, nommé par son empreinte.
/// Le texte y entre replié (`ContentSearch.fold`) : la recherche ignore accents et majuscules.
/// SearchKit n'est pas sûr entre fils : chaque appel passe par un verrou.
public final class ContentIndex: @unchecked Sendable {
    private let index: SKIndex
    private let lock = NSLock()

    /// Ouvre l'index, ou le crée. Un fichier abîmé est remplacé par un index vide.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            if let opened = SKIndexOpenWithURL(url as CFURL, nil, true)?.takeRetainedValue() {
                index = opened
                return
            }
            // Déjà ouvert ailleurs : lu tel quel plutôt que jeté. Seul un fichier illisible est remplacé.
            if let readOnly = SKIndexOpenWithURL(url as CFURL, nil, false)?.takeRetainedValue() {
                index = readOnly
                return
            }
        }
        try? FileManager.default.removeItem(at: url)
        let properties: [String: Any] = [kSKMinTermLength as String: 2]
        guard let created = SKIndexCreateWithURL(url as CFURL, nil, kSKIndexInverted, properties as CFDictionary)?
            .takeRetainedValue() else { throw BookError.unsupported("index de recherche impossible à créer") }
        index = created
    }

    private func document(_ id: String) -> SKDocument {
        SKDocumentCreate("alexandrie" as CFString, nil, id as CFString).takeRetainedValue()
    }

    /// Ajoute (ou remplace) le texte d'un livre.
    public func add(id: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        SKIndexAddDocumentWithText(index, document(id), ContentSearch.fold(text) as CFString, true)
    }

    public func remove(id: String) {
        lock.lock()
        defer { lock.unlock() }
        SKIndexRemoveDocument(index, document(id))
    }

    /// Écrit les ajouts sur le disque : sans cela, une recherche ne les voit pas encore.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        SKIndexFlush(index)
    }

    /// Livres qui contiennent tous les mots de la recherche (le dernier aussi en début de mot), les plus pertinents d'abord.
    public func search(_ query: String, limit: Int = 200) -> [String] {
        guard let text = ContentSearch.indexQuery(query) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let search = SKSearchCreate(index, text as CFString, SKSearchOptions(kSKSearchOptionDefault)).takeRetainedValue()
        var found: [(String, Float)] = []
        var more = true
        while more && found.count < limit {
            let batch = min(64, limit - found.count)
            var ids = [SKDocumentID](repeating: 0, count: batch)
            var scores = [Float](repeating: 0, count: batch)
            var count: CFIndex = 0
            more = SKSearchFindMatches(search, batch, &ids, &scores, 5, &count)
            for i in 0..<count {
                guard let doc = SKIndexCopyDocumentForDocumentID(index, ids[i])?.takeRetainedValue(),
                      let name = SKDocumentGetName(doc)?.takeUnretainedValue() as String? else { continue }
                found.append((name, scores[i]))
            }
            if count == 0 { break }
        }
        SKSearchCancel(search)
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
