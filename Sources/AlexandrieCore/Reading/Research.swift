import Foundation

/// Couleur nommée de la légende d'une thématique (S-075, S-079) : « Construction » porté par le jaune.
public struct ResearchTheme: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// « #RRGGBB », en sRGB.
    public var color: String

    public init(id: String = UUID().uuidString, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }

    /// Nom affiché : celui donné, sinon celui de la couleur de base qui le porte.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return HighlightColor.allCases.first { $0.hex == color.uppercased() }?.label ?? "Sans nom"
    }
}

/// Thématique (« Rénovation des voiries », un mémoire) : sa légende de couleurs, commune à tous ses livres.
public struct Research: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var themes: [ResearchTheme]

    public init(id: String = UUID().uuidString, name: String, themes: [ResearchTheme]) {
        self.id = id
        self.name = name
        self.themes = themes
    }

    /// Nouvelle recherche : les cinq couleurs de base, à nommer.
    public static func new(name: String) -> Research {
        Research(name: name, themes: HighlightColor.allCases.map { ResearchTheme(name: "", color: $0.hex) })
    }

    public func theme(id: String?) -> ResearchTheme? { themes.first { $0.id == id } }

    /// Teintes proposées pour une couleur ajoutée, après les cinq de base (teintes système de macOS).
    public static let extraColors = ["#FF9500", "#30B0C7", "#A2845E", "#5856D6", "#8E8E93", "#00C7BE", "#FF3B30"]

    /// Ajoute un thème, de la première teinte pas encore prise.
    @discardableResult
    public mutating func addTheme(name: String = "Nouvelle catégorie") -> ResearchTheme {
        let taken = Set(themes.map { $0.color.uppercased() })
        let color = (HighlightColor.allCases.map(\.hex) + Self.extraColors).first { !taken.contains($0) } ?? "#8E8E93"
        let theme = ResearchTheme(name: name, color: color)
        themes.append(theme)
        return theme
    }
}

/// Couleur d'un surlignage telle qu'affichée (S-079) : sa teinte, nommée par la légende d'une thématique
/// (« Construction ») ou, à défaut, par le nom de la couleur (« Jaune »).
public struct HighlightMark: Hashable, Identifiable, Sendable {
    /// La teinte « #RRGGBB » : deux thématiques qui nomment le même jaune parlent de la même couleur.
    public let key: String
    public let label: String
    public var hex: String { key }
    public var id: String { key }

    public init(hex: String, label: String) {
        key = hex.uppercased()
        self.label = label
    }

    public init(_ color: HighlightColor) {
        self.init(hex: color.hex, label: color.label)
    }

    public init(_ theme: ResearchTheme) {
        self.init(hex: theme.color, label: theme.displayName)
    }

    /// Rouge, vert et bleu (0 à 255).
    public var rgb: (Int, Int, Int) { HighlightColor.rgb(hex: hex) }

    /// Nom d'une teinte sans légende : celui de la couleur de base, ou « Couleur personnalisée ».
    public static func plainLabel(_ hex: String) -> String {
        HighlightColor.allCases.first { $0.hex == hex.uppercased() }?.label ?? "Couleur personnalisée"
    }
}

/// Thématiques enregistrées (S-075, S-079), et ce que chaque livre en retient.
/// Le type garde son nom d'origine, `Research` : une thématique est une recherche, un projet de lecture.
public struct ResearchList: Codable, Equatable, Sendable {
    public var researches: [Research] = []
    /// Thématique choisie dans la fenêtre de lecture, par empreinte de livre : les nouveaux surlignages y entrent.
    public var activeByBook: [String: String] = [:]
    /// Dernière couleur choisie (« #RRGGBB »), par thématique : celle du prochain surlignage.
    public var lastTheme: [String: String] = [:]

    public init(researches: [Research] = []) {
        self.researches = researches
    }

    public func research(id: String?) -> Research? { researches.first { $0.id == id } }

    /// Nom d'une teinte : dans la légende de la première des thématiques données qui la nomme.
    public func label(of hex: String, in thematics: [String]) -> String {
        let hex = hex.uppercased()
        for id in thematics {
            if let entry = research(id: id)?.themes.first(where: { $0.color.uppercased() == hex }) { return entry.displayName }
        }
        return HighlightMark.plainLabel(hex)
    }

    /// Couleur d'un surlignage, nommée par `thematic` si donnée, sinon par ses propres thématiques.
    public func mark(of clipping: Clipping, in thematic: String? = nil) -> HighlightMark {
        HighlightMark(hex: clipping.colorHex, label: label(of: clipping.colorHex, in: thematic.map { [$0] } ?? clipping.thematicIDs))
    }

    /// Couleurs proposées : la légende d'une thématique, ou les couleurs de base sans thématique.
    public func marks(in thematic: String?) -> [HighlightMark] {
        research(id: thematic).map { $0.themes.map(HighlightMark.init) } ?? HighlightColor.allCases.map(HighlightMark.init)
    }

    /// Couleurs proposées pour un surlignage : la légende de sa première thématique, plus sa couleur si elle n'y est pas.
    public func marks(for clipping: Clipping) -> [HighlightMark] {
        var list = marks(in: clipping.thematicIDs.first { research(id: $0) != nil })
        if !list.contains(where: { $0.key == clipping.colorHex.uppercased() }) { list.append(mark(of: clipping)) }
        return list
    }

    /// Couleur du prochain surlignage dans cette thématique (ou sans thématique, la couleur de base retenue).
    public func nextMark(in thematic: String?, base: HighlightColor) -> HighlightMark {
        guard let research = research(id: thematic), let first = research.themes.first else { return HighlightMark(base) }
        let last = research.themes.first { $0.color.uppercased() == lastTheme[research.id]?.uppercased() }
        return HighlightMark(last ?? first)
    }

    /// Reprend les surlignages d'avant S-079, rattachés à une recherche et à un thème : la recherche devient
    /// une de leurs thématiques, la couleur du thème leur couleur. Dit si quelque chose a changé.
    public func migrate(_ clippings: inout [Clipping]) -> Bool {
        var changed = false
        for i in clippings.indices where clippings[i].research != nil {
            let c = clippings[i]
            if let theme = research(id: c.research)?.theme(id: c.theme) { clippings[i].apply(HighlightMark(theme)) }
            if let id = c.research, research(id: id) != nil { clippings[i].setThematic(id, on: true) }
            clippings[i].research = nil
            clippings[i].theme = nil
            changed = true
        }
        return changed
    }

    public static func load(_ url: URL) -> ResearchList {
        guard let data = try? Data(contentsOf: url) else { return ResearchList() }
        return (try? JSONDecoder().decode(ResearchList.self, from: data)) ?? ResearchList()
    }

    public static func save(_ list: ResearchList, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(list).write(to: url, options: .atomic)
    }
}

public extension Clipping {
    /// Teinte du surlignage (« #RRGGBB ») : une couleur de base, ou une couleur ajoutée à une légende.
    var colorHex: String { (hue ?? highlightColor.hex).uppercased() }

    /// Thématiques du surlignage (S-079), dans l'ordre où elles ont été données.
    var thematicIDs: [String] { thematics ?? [] }

    /// Donne au surlignage une couleur ; ses thématiques ne changent pas.
    mutating func apply(_ mark: HighlightMark) {
        if let base = HighlightColor.allCases.first(where: { $0.hex == mark.hex }) {
            color = base == .yellow ? nil : base
            hue = nil
        } else {
            color = nil
            hue = mark.hex
        }
    }

    /// Range le surlignage dans une thématique, ou l'en retire.
    mutating func setThematic(_ id: String, on: Bool) {
        var list = thematicIDs.filter { $0 != id }
        if on { list.append(id) }
        thematics = list.isEmpty ? nil : list
    }
}

public extension HighlightColor {
    /// Teintes système de macOS, en sRGB.
    var hex: String {
        switch self {
        case .yellow: "#FFCC00"
        case .green: "#34C759"
        case .blue: "#0A84FF"
        case .pink: "#FF375F"
        case .purple: "#AF52DE"
        }
    }

    var rgb: (Int, Int, Int) { Self.rgb(hex: hex) }

    static func rgb(hex: String) -> (Int, Int, Int) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFCC00
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    static func hex(red: Int, green: Int, blue: Int) -> String {
        String(format: "#%02X%02X%02X", min(max(red, 0), 255), min(max(green, 0), 255), min(max(blue, 0), 255))
    }

    /// Couleur de base la plus proche d'une teinte.
    static func nearest(hex: String) -> HighlightColor {
        let (r, g, b) = rgb(hex: hex)
        return allCases.min { a, b2 in
            let (ar, ag, ab) = a.rgb, (br, bg, bb) = b2.rgb
            return (ar - r) * (ar - r) + (ag - g) * (ag - g) + (ab - b) * (ab - b)
                < (br - r) * (br - r) + (bg - g) * (bg - g) + (bb - b) * (bb - b)
        } ?? .yellow
    }
}

/// Ordre des passages d'une thématique (S-080).
public enum ThematicOrder: String, CaseIterable, Identifiable, Sendable {
    case color, book, added

    public var id: Self { self }

    public var label: String {
        switch self {
        case .color: "Par couleur"
        case .book: "Par livre"
        case .added: "Par date d'ajout"
        }
    }
}

/// Groupe de passages d'une thématique : une couleur nommée, un livre, ou tous par date.
public struct ThematicSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    /// Teinte du groupe quand il est rangé par couleur.
    public let hex: String?
    public let clippings: [Clipping]
}

/// Export d'une thématique entière (S-078, S-079, S-080) : tous ses livres, pour rédiger.
public enum ResearchExport {
    /// Passages de la thématique (surlignages et notes rangés dedans), groupés selon l'ordre choisi.
    /// `clippings` est dans l'ordre d'ajout (celui du fichier des notes).
    public static func sections(_ research: Research, clippings: [Clipping], order: ThematicOrder) -> [ThematicSection] {
        let mine = clippings.filter { $0.thematicIDs.contains(research.id) && $0.kind != .bookmark && !$0.isHidden }
        let byBookThenReading: ([Clipping]) -> [Clipping] = { list in
            Dictionary(grouping: list) { ShelfSync.normalize($0.title) }
                .sorted { $0.key < $1.key }
                .flatMap { KindleClippings.readingOrder($0.value) }
        }
        switch order {
        case .color:
            var groups = research.themes.map { (hex: $0.color.uppercased(), title: $0.displayName) }
            for hex in mine.map(\.colorHex) where !groups.contains(where: { $0.hex == hex }) {
                groups.append((hex, HighlightMark.plainLabel(hex)))
            }
            return groups.compactMap { group in
                let list = mine.filter { $0.colorHex == group.hex }
                return list.isEmpty ? nil
                    : ThematicSection(id: group.hex, title: group.title, hex: group.hex, clippings: byBookThenReading(list))
            }
        case .book:
            return Dictionary(grouping: mine) { ShelfSync.normalize($0.title) }
                .sorted { $0.key < $1.key }
                .map { key, list in
                    let first = list[0]
                    let title = first.title + (first.author.isEmpty ? "" : " — \(first.author)")
                    return ThematicSection(id: key, title: title, hex: nil, clippings: KindleClippings.readingOrder(list))
                }
        case .added:
            return mine.isEmpty ? [] : [ThematicSection(id: "added", title: "", hex: nil, clippings: mine.reversed())]
        }
    }

    /// Markdown dans l'ordre choisi : un titre par couleur nommée (puis par livre), par livre, ou une seule
    /// liste par date ; chaque passage avec sa source, sa couleur nommée quand elle n'est pas le titre, et sa note.
    public static func markdown(_ research: Research, clippings: [Clipping], order: ThematicOrder = .color) -> String {
        let all = sections(research, clippings: clippings, order: order)
        let count = all.reduce(0) { $0 + $1.clippings.count }
        let books = Set(all.flatMap(\.clippings).map { ShelfSync.normalize($0.title) }).count
        let list = ResearchList(researches: [research])
        var out = "# \(research.name)\n\n*\(count) passage\(count > 1 ? "s" : ""), "
            + "\(books) livre\(books > 1 ? "s" : "")*\n"
        for section in all {
            if !section.title.isEmpty { out += "\n## \(section.title)\n" }
            var currentBook = ""
            for c in section.clippings {
                if order == .color, ShelfSync.normalize(c.title) != currentBook {
                    currentBook = ShelfSync.normalize(c.title)
                    out += "\n### \(c.title)" + (c.author.isEmpty ? "" : " — \(c.author)") + "\n"
                }
                let quote = c.kind == .note ? "📝 " + c.displayText : "> " + c.displayText.replacingOccurrences(of: "\n", with: "\n> ")
                out += "\n" + quote + "\n"
                if let note = c.note, c.hasNote { out += "\n📝 \(note)\n" }
                let category = order == .color || c.kind == .note ? "" : list.mark(of: c, in: research.id).label
                let source = [order == .book ? "" : c.title, category, c.location, c.added].filter { !$0.isEmpty }
                out += "\n<small>\(source.joined(separator: " · "))</small>\n"
            }
        }
        return out
    }
}
