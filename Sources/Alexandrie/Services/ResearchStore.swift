import AlexandrieCore
import Foundation
import Observation

/// Thématiques et leurs légendes de couleurs (S-075, S-079), enregistrées dans `researches.json`.
/// Les surlignages gardent leur couleur et leurs thématiques dans les notes (`KindleMonitor`).
@MainActor @Observable
final class ResearchStore {
    private(set) var list: ResearchList
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let kindle: KindleMonitor

    init(directories: AppDirectories, kindle: KindleMonitor) {
        url = directories.researches
        list = ResearchList.load(directories.researches)
        self.kindle = kindle
        // Le travail d'un mémoire : une copie datée par jour, comme la bibliothèque et les notes (audit, § 2).
        _ = try? IndexBackups.backUpToday(directories.researches, to: directories.backups, name: "researches")
        // Surlignages d'avant S-079 (recherche et thème) : leur thématique et leur couleur sont reprises.
        let list = list
        kindle.modifyClippings { c in
            guard c.research != nil else { return false }
            var one = [c]
            _ = list.migrate(&one)
            c = one[0]
            return true
        }
    }

    var researches: [Research] { list.researches }

    func research(id: String?) -> Research? { list.research(id: id) }

    /// Couleur d'un surlignage, nommée par `thematic` si donnée, sinon par ses thématiques.
    func mark(of clipping: Clipping, in thematic: String? = nil) -> HighlightMark { list.mark(of: clipping, in: thematic) }

    /// Couleurs proposées pour un surlignage : la légende de sa thématique, ou les couleurs de base.
    func marks(for clipping: Clipping) -> [HighlightMark] { list.marks(for: clipping) }

    /// Noms des thématiques d'un surlignage.
    func thematicNames(of clipping: Clipping) -> [String] { clipping.thematicIDs.compactMap { research(id: $0)?.name } }

    // MARK: Thématique choisie en lisant (S-076, S-079)

    func activeResearch(for book: Book) -> Research? { research(id: list.activeByBook[book.fingerprint]) }

    func setActive(_ id: String?, for book: Book) {
        list.activeByBook[book.fingerprint] = id
        save()
    }

    /// Couleur et thématique du prochain surlignage de ce livre.
    func nextMark(for book: Book) -> (mark: HighlightMark, research: String?) {
        let research = activeResearch(for: book)?.id
        return (list.nextMark(in: research, base: HighlightColor.current), research)
    }

    /// Retient la couleur choisie pour les prochains surlignages, dans la thématique donnée ou sans thématique.
    func remember(_ mark: HighlightMark, in researchID: String?) {
        if let researchID, research(id: researchID) != nil {
            list.lastTheme[researchID] = mark.hex
            save()
        }
        if let color = HighlightColor.allCases.first(where: { $0.hex == mark.hex }) { HighlightColor.current = color }
    }

    /// Change la couleur d'un surlignage et la retient pour les suivants.
    func apply(_ mark: HighlightMark, to id: Clipping.ID) {
        kindle.setMark(id, mark)
        remember(mark, in: kindle.clipping(id: id)?.thematicIDs.first)
    }

    /// Range un surlignage dans une thématique, ou l'en retire.
    func setThematic(_ thematic: String, on: Bool, for id: Clipping.ID) {
        kindle.setThematic(id, thematic, on: on)
    }

    // MARK: Gestion des thématiques (S-075, S-079)

    @discardableResult
    func addResearch(name: String = "Nouvelle thématique") -> Research {
        let research = Research.new(name: name)
        list.researches.append(research)
        save()
        return research
    }

    /// Enregistre une thématique modifiée (nom, légende). Les surlignages gardent leur couleur.
    func update(_ research: Research) {
        guard let i = list.researches.firstIndex(where: { $0.id == research.id }) else { return }
        list.researches[i] = research
        save()
    }

    /// Supprime une thématique : elle est retirée de ses surlignages, qui gardent leur couleur.
    func delete(_ id: String) {
        list.researches.removeAll { $0.id == id }
        list.activeByBook = list.activeByBook.filter { $0.value != id }
        list.lastTheme[id] = nil
        save()
        kindle.modifyClippings { c in
            guard c.thematicIDs.contains(id) else { return false }
            c.setThematic(id, on: false)
            return true
        }
    }

    /// Nombre de surlignages d'une thématique (ou de ceux d'une de ses couleurs).
    func highlightCount(research id: String, color: String? = nil) -> Int {
        kindle.clippings.filter {
            $0.thematicIDs.contains(id) && !$0.isHidden && (color == nil || $0.colorHex == color?.uppercased())
        }.count
    }

    /// Livres lus pour une thématique (ceux qui y ont des surlignages).
    func bookCount(research id: String) -> Int {
        Set(kindle.clippings.filter { $0.thematicIDs.contains(id) && !$0.isHidden }.map { ShelfSync.normalize($0.title) }).count
    }

    /// Markdown de toute la thématique, classé par couleur nommée puis par livre (S-078, S-079).
    func exportMarkdown(research id: String) -> String? {
        research(id: id).map { ResearchExport.markdown($0, clippings: kindle.clippings) }
    }

    /// Un échec (disque plein, dossier verrouillé) est signalé : les thématiques ne se perdent pas en silence.
    private func save() {
        do {
            try ResearchList.save(list, to: url)
        } catch {
            kindle.lastError = "Impossible d'enregistrer les thématiques : \(error.localizedDescription)"
        }
    }
}
