import Foundation

/// Faux Zotero en mémoire (tests, self-test, captures) : même protocole que l'API locale, sans réseau.
public final class ZoteroMemoryServer: @unchecked Sendable {
    struct Stored {
        var json: [String: Any]
        var version: Int
        var deleted = false
    }

    private let lock = NSLock()
    private var items: [String: Stored] = [:]
    private var order: [String] = []
    private var counter = 0
    public var enabled = true
    /// Réponse à la fenêtre d'autorisation : `remember` (« Toujours autoriser »), ou refus si nil.
    public var authorizeRemember: Bool? = true
    public private(set) var authorizeCount = 0
    public private(set) var requests: [ZoteroRequest] = []
    public let serverID = "memoryServer"
    private var keys: Set<String> = []

    public init() {}

    public var transport: ZoteroLocalClient.Transport { { [self] request in handle(request) } }

    /// Éléments présents (hors supprimés), dans l'ordre de création.
    public func list() -> [(key: String, json: [String: Any], version: Int)] {
        lock.withLock { order.compactMap { k in items[k].flatMap { $0.deleted ? nil : (k, $0.json, $0.version) } } }
    }

    public func delete(_ key: String) { lock.withLock { items[key]?.deleted = true } }

    /// Modification faite dans Zotero (la version avance).
    public func touch(_ key: String) { lock.withLock { counter += 1; items[key]?.version = counter } }

    public func revokeKeys() { lock.withLock { keys = [] } }

    func handle(_ r: ZoteroRequest) -> ZoteroResponse {
        lock.withLock {
            requests.append(r)
            guard enabled else { return ZoteroResponse(status: 403, data: Data("Local API is not enabled".utf8)) }
            let head = ["Zotero-Server-ID": serverID]
            switch (r.method, r.path) {
            case ("GET", "/"):
                return ZoteroResponse(status: 200, headers: head, data: Data("Nothing to see here.".utf8))
            case ("POST", "/local/authorize"):
                authorizeCount += 1
                guard let remember = authorizeRemember else { return ZoteroResponse(status: 403, data: Data(#"{"denied":true}"#.utf8)) }
                let key = "key\(authorizeCount)"
                keys.insert(key)
                return json(["key": key, "remember": remember])
            case ("GET", "/users/0/items"):
                let q = (r.query.first { $0.name == "q" }?.value ?? "").lowercased().split(separator: " ")
                let found = order.compactMap { k -> [String: Any]? in
                    guard let s = items[k], !s.deleted else { return nil }
                    let type = s.json["itemType"] as? String ?? ""
                    guard type == "book" || type == "bookSection" else { return nil }
                    let hay = ((s.json["title"] as? String ?? "") + " " + creators(s.json)).lowercased()
                    guard q.allSatisfy({ hay.contains($0) }) else { return nil }
                    return wrap(k, s)
                }
                return json(found)
            case ("GET", let path) where path.hasPrefix("/users/0/items/"):
                let key = String(path.dropFirst("/users/0/items/".count))
                guard let s = items[key], !s.deleted else { return ZoteroResponse(status: 404) }
                return json(wrap(key, s))
            case ("POST", "/users/0/items"):
                if let denied = writeCheck(r) { return denied }
                guard let body = r.body, let list = try? JSONSerialization.jsonObject(with: body) as? [[String: Any]],
                      let object = list.first else { return ZoteroResponse(status: 400) }
                if let parent = object["parentItem"] as? String, items[parent] == nil || items[parent]!.deleted {
                    return json(["successful": [:], "failed": ["0": ["code": 400, "message": "Parent item not found"]]])
                }
                counter += 1
                let key = String(format: "K%07d", counter)
                items[key] = Stored(json: object, version: counter)
                order.append(key)
                return json(["successful": ["0": ["key": key, "version": counter]], "success": ["0": key]],
                            headers: ["Last-Modified-Version": "\(counter)"])
            case ("PATCH", let path) where path.hasPrefix("/users/0/items/"):
                if let denied = writeCheck(r) { return denied }
                let key = String(path.dropFirst("/users/0/items/".count))
                guard var s = items[key], !s.deleted else { return ZoteroResponse(status: 404) }
                guard r.headers["If-Unmodified-Since-Version"] == "\(s.version)" else { return ZoteroResponse(status: 412) }
                if let body = r.body, let patch = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    var j = s.json
                    for (k, v) in patch { j[k] = v }
                    s.json = j
                }
                counter += 1
                s.version = counter
                items[key] = s
                return ZoteroResponse(status: 204, headers: ["Last-Modified-Version": "\(counter)"])
            default:
                return ZoteroResponse(status: 404)
            }
        }
    }

    private func writeCheck(_ r: ZoteroRequest) -> ZoteroResponse? {
        guard r.headers["Zotero-Server-ID"] == serverID else { return ZoteroResponse(status: 428) }
        guard let key = r.headers["Zotero-API-Key"], keys.contains(key) else { return ZoteroResponse(status: 401) }
        return nil
    }

    private func creators(_ j: [String: Any]) -> String {
        (j["creators"] as? [[String: String]] ?? []).map { [$0["firstName"], $0["lastName"], $0["name"]].compactMap { $0 }.joined(separator: " ") }
            .joined(separator: " ")
    }

    private func wrap(_ key: String, _ s: Stored) -> [String: Any] {
        var data = s.json
        data["key"] = key
        data["version"] = s.version
        return ["key": key, "version": s.version, "data": data]
    }

    private func json(_ object: Any, headers: [String: String] = [:]) -> ZoteroResponse {
        ZoteroResponse(status: 200, headers: headers, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }
}
