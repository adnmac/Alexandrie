import Foundation

/// Image disque (.dmg) d'une version publiée : scripts/release.sh y met Foluna.app et un lien vers Applications.
public enum DiskImage {
    public enum Failure: LocalizedError, Equatable {
        case tool(String)
        case appMissing

        public var errorDescription: String? {
            switch self {
            case .tool(let why): String(localized: "Image disque illisible : \(why).")
            case .appMissing: String(localized: "L'image disque ne contient pas Foluna.app.")
            }
        }
    }

    /// Monte l'image en lecture seule (sans l'afficher dans le Finder), copie l'app qu'elle contient dans `folder`,
    /// puis la démonte. Rend l'URL de la copie.
    public static func extractApp(named names: [String] = ["Foluna.app", "Alexandrie.app"], from dmg: URL, to folder: URL) throws -> URL {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("foluna-dmg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let name = names.first(where: { fm.fileExists(atPath: mount.appendingPathComponent($0).path) }) else {
            throw Failure.appMissing
        }
        let source = mount.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(name)
        try? fm.removeItem(at: copy)
        try run("/usr/bin/ditto", [source.path, copy.path])
        return copy
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.terminationStatus == 0 else {
            throw Failure.tool(text.isEmpty ? "\((tool as NSString).lastPathComponent) \(p.terminationStatus)" : text)
        }
        return text
    }
}

/// Remplacement de l'app une fois qu'elle est fermée : un script attend la fin du processus, met la nouvelle
/// version à la place de l'ancienne (l'ancienne revient si la copie échoue), puis relance l'app.
public enum UpdateInstall {
    /// Arguments : $0 le processus à attendre, $1 la nouvelle app, $2 l'app installée, $3 « open » pour relancer,
    /// $4 un dossier de travail à effacer à la fin (facultatif), $5 l'emplacement de la nouvelle app (par défaut
    /// celui de l'app installée ; autre nom quand l'app change de nom, Alexandrie.app → Foluna.app).
    public static let script = #"""
        pid="$0"; new="$1"; installed="$2"; relaunch="$3"; work="$4"; dest="${5:-$2}"
        i=0
        while kill -0 "$pid" 2>/dev/null; do
          sleep 0.2; i=$((i+1))
          [ "$i" -gt 300 ] && exit 1
        done
        old="$installed.old-$$"
        if mv "$installed" "$old"; then
          if /usr/bin/ditto "$new" "$dest"; then
            rm -rf "$old"
          else
            rm -rf "$dest"; mv "$old" "$installed"; dest="$installed"
          fi
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null
        [ -n "$work" ] && rm -rf "$work"
        [ "$relaunch" = "open" ] && /usr/bin/open "$dest"
        exit 0
        """#

    /// Lance le script en arrière-plan ; il survit à la fermeture de l'app.
    public static func launch(waitingFor pid: Int32, newApp: URL, installedApp: URL, destination: URL? = nil,
                              relaunch: Bool = true, cleaning work: URL? = nil) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, String(pid), newApp.path, installedApp.path, relaunch ? "open" : "", work?.path ?? "",
                       (destination ?? installedApp).path]
        try p.run()
        return p
    }
}
