import Foundation

/// Ce que produit un importeur : un livre au texte redimensionnable (EPUB, puis AZW3 pour la Kindle),
/// ou des pages en images (bande dessinée : EPUB d'une image par page, PDF pour la Kindle).
public enum ImportOutput: Sendable {
    case reflowable
    case pages
}

/// Importeur d'un format de livre : lit ses informations et le convertit en `ImportedDocument`, d'où l'app
/// tire l'EPUB (lecture, Kobo, liseuses EPUB), l'AZW3 ou le PDF (Kindle) et le texte (recherche).
/// Un importeur ne modifie jamais le fichier lu et n'écrit rien lui-même : l'EPUB est écrit par l'app.
public protocol BookImporter: Sendable {
    /// Identifiant stable, gardé dans les réglages (formats désactivés).
    static var id: String { get }
    static var formats: [BookFormat] { get }
    static var output: ImportOutput { get }
    /// Version de la conversion : la changer refait les copies envoyées (pas la copie de lecture, voir `ReaderBook`).
    static var version: Int { get }
    /// Le fichier est-il bien de ce format ? Lu sur ses premiers octets (`Importers.headerLength`).
    static func detect(_ header: Data) -> Bool
    /// Informations et couverture, pour l'indexation ; plus rapide que `document(of:)` quand c'est possible.
    static func metadata(of url: URL) throws -> BookMetadata
    /// Livre complet.
    static func document(of url: URL) throws -> ImportedDocument
}

extension BookImporter {
    public static func metadata(of url: URL) throws -> BookMetadata {
        try document(of: url).metadataWithCover
    }
}

/// Registre des importeurs et formats activés (Réglages › Formats).
public enum Importers {
    public static var all: [any BookImporter.Type] { [FB2Importer.self, CBZImporter.self, TXTImporter.self] }

    /// Octets lus pour reconnaître un fichier.
    public static let headerLength = 256

    public static func importer(for format: BookFormat) -> (any BookImporter.Type)? {
        all.first { $0.formats.contains(format) }
    }

    // MARK: Formats activés

    /// Clé des réglages : formats désactivés (une liste, pour qu'un format ajouté par une mise à jour soit actif).
    public static let disabledFormatsKey = "disabledFormats"

    /// Formats désactivés par l'utilisateur. EPUB, MOBI, AZW3, AZW et PDF ne le sont jamais.
    public static func disabledFormats(_ defaults: UserDefaults = .standard) -> Set<BookFormat> {
        Set((defaults.stringArray(forKey: disabledFormatsKey) ?? []).compactMap(BookFormat.init(rawValue:))
            .filter(\.isOptional))
    }

    public static func setEnabled(_ format: BookFormat, _ enabled: Bool, defaults: UserDefaults = .standard) {
        guard format.isOptional else { return }
        var disabled = disabledFormats(defaults)
        if enabled { disabled.remove(format) } else { disabled.insert(format) }
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: disabledFormatsKey)
    }

    // MARK: Conversions

    /// EPUB du livre, avec les informations corrigées dans l'app.
    public static func writeEPUB(_ input: URL, format: BookFormat, to output: URL, edits: MetadataEdits?) throws {
        try document(input, format: format).writeEPUB(to: output, edits: edits)
    }

    /// PDF d'une page par image (bande dessinée pour la Kindle).
    public static func writePDF(_ input: URL, format: BookFormat, to output: URL, edits: MetadataEdits?) throws {
        try document(input, format: format).writePDF(to: output, edits: edits)
    }

    /// Texte du livre, un morceau par chapitre (recherche dans le contenu).
    public static func text(_ input: URL, format: BookFormat) throws -> [String] {
        try document(input, format: format).plainTexts
    }

    static func document(_ input: URL, format: BookFormat) throws -> ImportedDocument {
        guard let importer = importer(for: format) else { throw BookError.unsupported("format \(format.label)") }
        try ImportLimits.checkFileSize(input)
        return try importer.document(of: input)
    }

    /// Premiers octets d'un fichier.
    static func header(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: headerLength)) ?? Data()
    }
}
