import Foundation

/// Note de bas de page (ou de fin) d'un livre, telle que le panneau des notes la montre (S-103).
public struct Footnote: Sendable, Equatable, Identifiable {
    /// Adresse de la note dans le livre extrait : chemin du fichier et ancre (`…/notes.xhtml#n12`).
    public let id: String
    /// Appel de la note dans le texte (« 1 », « * »…).
    public let label: String
    /// Paragraphes du texte de la note, sans balises ni lien de retour.
    public let paragraphs: [String]

    public init(id: String, label: String, paragraphs: [String]) {
        self.id = id
        self.label = label
        self.paragraphs = paragraphs
    }

    public var text: String { paragraphs.joined(separator: "\n") }

    /// Une note courte s'ouvre en bulle sur son appel ; une longue, dans le panneau.
    public static let shortLength = 300
    public var isShort: Bool { text.count <= Self.shortLength }
}

/// Lit le texte des notes dans les fichiers XHTML d'un livre extrait (S-103).
///
/// Une note est l'élément dont l'identifiant est l'ancre de l'appel. Quand cet identifiant est posé sur
/// une ancre ou un numéro au début de la note (`<p><a id="n1">1.</a> Texte</p>`), la note est le bloc qui le contient.
public enum Footnotes {
    /// Éléments qui contiennent une note entière.
    static let blocks: Set<String> = ["aside", "li", "p", "div", "section", "dd", "dt", "td", "blockquote", "footer", "note"]
    /// Liens de retour vers l'appel, retirés du texte.
    static let backLinks: Set<String> = ["↩", "↩︎", "↑", "^", "⤴", "retour", "back"]

    /// Paragraphes de la note `fragment` du document XHTML (ou HTML) `data` ; nil si l'ancre n'existe pas.
    public static func paragraphs(of fragment: String, in data: Data, label: String = "") -> [String]? {
        guard let document = parse(data), let root = document.rootElement(),
              let target = element(withID: fragment, in: root) else { return nil }
        let note = container(of: target)
        let parts = paragraphElements(of: note).map { text(of: $0) }.filter { !$0.isEmpty }
        let cleaned = strip(label: label, from: parts)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Note complète, d'après l'adresse absolue de l'appel (`file:///…/chapitre.xhtml#n1`).
    /// Les fichiers lus sont gardés dans `cache` : un chapitre de notes sert à toutes ses notes.
    public static func note(at url: URL, label: String, under root: URL, cache: inout [String: Data]) -> Footnote? {
        guard url.isFileURL, let fragment = url.fragment, !fragment.isEmpty else { return nil }
        let path = url.standardizedFileURL.path
        // Jamais hors du dossier du livre extrait.
        guard path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        let data: Data
        if let cached = cache[path] { data = cached } else {
            guard let read = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            cache[path] = read
            data = read
        }
        guard let paragraphs = paragraphs(of: fragment.removingPercentEncoding ?? fragment, in: data, label: label) else { return nil }
        return Footnote(id: "\(path)#\(fragment)", label: label, paragraphs: paragraphs)
    }

    // MARK: Lecture du document

    static func parse(_ data: Data) -> XMLDocument? {
        if let xml = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) { return xml }
        // Un HTML mal formé (EPUB 2 négligé) passe par la réparation de libxml.
        return try? XMLDocument(data: data, options: [.documentTidyHTML, .nodePreserveWhitespace])
    }

    static func element(withID id: String, in root: XMLElement) -> XMLElement? {
        var stack: [XMLElement] = [root]
        while let element = stack.popLast() {
            if element.attribute(forName: "id")?.stringValue == id || element.attribute(forName: "xml:id")?.stringValue == id
                || element.attribute(forName: "name")?.stringValue == id && localName(element) == "a" {
                return element
            }
            stack.append(contentsOf: (element.children ?? []).compactMap { $0 as? XMLElement }.reversed())
        }
        return nil
    }

    static func localName(_ element: XMLElement) -> String {
        (element.localName ?? element.name ?? "").lowercased()
    }

    /// Bloc de la note : l'élément visé s'il est un bloc, sinon le premier bloc qui le contient.
    static func container(of target: XMLElement) -> XMLElement {
        var current: XMLElement? = target
        while let element = current {
            let name = localName(element)
            if name == "body" { return target }
            if blocks.contains(name) { return element }
            current = element.parent as? XMLElement
        }
        return target
    }

    /// Paragraphes de la note : ses blocs enfants, ou la note entière si elle n'en a pas.
    static func paragraphElements(of note: XMLElement) -> [XMLElement] {
        let children = (note.children ?? []).compactMap { $0 as? XMLElement }
        let paragraphs = children.filter { ["p", "div", "blockquote", "li", "dd"].contains(localName($0)) }
        return paragraphs.isEmpty ? [note] : paragraphs
    }

    /// Texte d'un élément, blancs réduits, sans les liens de retour vers l'appel.
    static func text(of element: XMLElement) -> String {
        var out = ""
        func walk(_ node: XMLNode) {
            if let element = node as? XMLElement {
                let name = localName(element)
                if name == "a", isBackLink(element) { return }
                if ["script", "style"].contains(name) { return }
                if name == "br" { out += " " }
                for child in element.children ?? [] { walk(child) }
            } else if node.kind == .text {
                out += node.stringValue ?? ""
            }
        }
        walk(element)
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isBackLink(_ a: XMLElement) -> Bool {
        let role = a.attribute(forName: "role")?.stringValue ?? ""
        let type = a.attribute(forName: "epub:type")?.stringValue ?? ""
        if role == "doc-backlink" || type.split(separator: " ").contains("backlink") { return true }
        let text = (a.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return backLinks.contains(text)
    }

    /// Retire le numéro de la note répété au début de son texte (« 1. », « [1] », « 1) »).
    static func strip(label: String, from parts: [String]) -> [String] {
        guard var first = parts.first else { return parts }
        let label = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]() "))
        guard !label.isEmpty else { return parts }
        for prefix in ["[\(label)]", "(\(label))", "\(label).", "\(label))", "\(label) ", "\(label)\u{00A0}"] where first.hasPrefix(prefix) {
            first = String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if first == label { first = "" }
        return ([first] + parts.dropFirst()).filter { !$0.isEmpty }
    }
}
