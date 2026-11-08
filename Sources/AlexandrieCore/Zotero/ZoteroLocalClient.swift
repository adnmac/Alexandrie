import Foundation

/// Requête vers l'API locale de Zotero (Zotero 10+, `127.0.0.1:23119`).
public struct ZoteroRequest: Sendable, Equatable {
    public var method: String
    /// Chemin sous `/api` (« /users/0/items »).
    public var path: String
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?

    public init(_ method: String, _ path: String, query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct ZoteroResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    /// En-tête sans tenir compte de la casse.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public enum ZoteroError: LocalizedError, Equatable {
    /// Zotero n'est pas ouvert (rien n'écoute sur le port 23119).
    case notRunning
    /// Case « Autoriser d'autres applications… » décochée.
    case localAPIDisabled
    /// Zotero trop ancien pour écrire (Zotero 10 ou plus récent requis).
    case tooOld
    case denied
    /// Trop de demandes d'autorisation (5 par minute).
    case tooManyRequests
    /// Clé refusée : il faut redemander l'autorisation.
    case unauthorized
    /// Élément modifié dans Zotero depuis sa lecture.
    case conflict
    case notFound
    case failed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "Zotero n'est pas ouvert : lancez-le, puis réessayez."
        case .localAPIDisabled: "Dans Zotero, cochez Réglages › Avancés › « Autoriser d'autres applications de cet ordinateur à communiquer avec Zotero »."
        case .tooOld: "Cette version de Zotero ne permet pas aux autres applications d'écrire : il faut Zotero 10 ou plus récent."
        case .denied: "Zotero a refusé l'accès. Réessayez et choisissez « Toujours autoriser »."
        case .tooManyRequests: "Trop de demandes d'autorisation : attendez une minute."
        case .unauthorized: "L'autorisation donnée par Zotero n'est plus valable : réessayez pour la redonner."
        case .conflict: "La note a été modifiée dans Zotero en même temps : réessayez."
        case .notFound: "Élément introuvable dans Zotero."
        case .failed(let status, let message): "Zotero a répondu \(status)" + (message.isEmpty ? "." : " : \(message)")
        }
    }
}

/// Élément Zotero lu : clé, version, et champs utiles.
public struct ZoteroItem: Sendable, Equatable {
    public var key: String
    public var version: Int
    public var itemType: String
    public var title: String
    public var isbn: String?
    /// Noms des auteurs, « Nom » ou « Prénom Nom ».
    public var creators: [String]
    public var parentItem: String?
    public var deleted: Bool

    public init(key: String, version: Int, itemType: String, title: String = "", isbn: String? = nil,
                creators: [String] = [], parentItem: String? = nil, deleted: Bool = false) {
        self.key = key
        self.version = version
        self.itemType = itemType
        self.title = title
        self.isbn = isbn
        self.creators = creators
        self.parentItem = parentItem
        self.deleted = deleted
    }

    init?(json: [String: Any]) {
        guard let key = json["key"] as? String, let data = json["data"] as? [String: Any] else { return nil }
        let creators = (data["creators"] as? [[String: Any]] ?? []).compactMap { c -> String? in
            if let name = c["name"] as? String { return name }
            let parts = [c["firstName"] as? String, c["lastName"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        let isbn = (data["ISBN"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(key: key, version: json["version"] as? Int ?? data["version"] as? Int ?? 0,
                  itemType: data["itemType"] as? String ?? "", title: data["title"] as? String ?? "",
                  isbn: isbn, creators: creators, parentItem: data["parentItem"] as? String,
                  deleted: (data["deleted"] as? Bool ?? false) || (data["deleted"] as? Int ?? 0) == 1)
    }
}

/// Client de l'API locale de Zotero : lecture des références, autorisation d'écrire, création et mise à jour.
/// Rien ne sort du Mac : l'adresse est toujours `127.0.0.1:23119`.
public struct ZoteroLocalClient: Sendable {
    public typealias Transport = @Sendable (ZoteroRequest) async throws -> ZoteroResponse
    public static let base = URL(string: "http://127.0.0.1:23119/api")!
    let transport: Transport

    public init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            var url = Self.base.appendingPathComponent(String(request.path.drop { $0 == "/" }))
            if !request.query.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.queryItems = request.query
                url = c.url ?? url
            }
            var r = URLRequest(url: url, timeoutInterval: request.path.hasSuffix("authorize") ? 120 : 15)
            r.httpMethod = request.method
            r.httpBody = request.body
            r.setValue(UserAgent.value, forHTTPHeaderField: "User-Agent")
            r.setValue("3", forHTTPHeaderField: "Zotero-API-Version")
            if request.body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
            do {
                let (data, response) = try await URLSession.shared.data(for: r)
                let http = response as? HTTPURLResponse
                let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { out, pair in
                    if let k = pair.key as? String { out[k] = "\(pair.value)" }
                }
                return ZoteroResponse(status: http?.statusCode ?? 0, headers: headers, data: data)
            } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .timedOut,
                                                  .cannotFindHost].contains(error.code) {
                throw ZoteroError.notRunning
            }
        }
    }

    // MARK: - Appels

    /// Identifiant du serveur (`Zotero-Server-ID`), exigé sur chaque écriture.
    public func serverID() async throws -> String {
        let r = try await send(ZoteroRequest("GET", "/"))
        try check(r)
        guard let id = r.header("Zotero-Server-ID") else { throw ZoteroError.tooOld }
        return id
    }

    /// Lecture : vérifie aussi que l'API locale est activée.
    public func checkReadable() async throws {
        try check(try await send(ZoteroRequest("GET", "/users/0/items", query: [URLQueryItem(name: "limit", value: "1")])))
    }

    /// Demande à Zotero d'autoriser l'écriture (fenêtre « Autoriser / Toujours autoriser / Refuser »).
    /// Rend la clé et si elle est réutilisable (« Toujours autoriser »).
    public func authorize(appName: String, serverID: String) async throws -> (key: String, remember: Bool) {
        let body = try JSONSerialization.data(withJSONObject: ["appName": appName])
        let r = try await send(ZoteroRequest("POST", "/local/authorize", headers: ["Zotero-Server-ID": serverID], body: body))
        if r.status == 404 || r.status == 405 { throw ZoteroError.tooOld }
        try check(r)
        guard let json = try JSONSerialization.jsonObject(with: r.data) as? [String: Any],
              let key = json["key"] as? String, !key.isEmpty else { throw ZoteroError.failed(r.status, "réponse illisible") }
        return (key, json["remember"] as? Bool ?? false)
    }

    /// Livres et chapitres trouvés par titre et auteurs (`q`), hors corbeille.
    public func searchBooks(_ terms: String) async throws -> [ZoteroItem] {
        let r = try await send(ZoteroRequest("GET", "/users/0/items", query: [
            URLQueryItem(name: "q", value: terms), URLQueryItem(name: "itemType", value: "book || bookSection"),
            URLQueryItem(name: "includeTrashed", value: "0"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "50"),
        ]))
        try check(r)
        let list = try JSONSerialization.jsonObject(with: r.data) as? [[String: Any]] ?? []
        return list.compactMap(ZoteroItem.init(json:)).filter { !$0.deleted }
    }

    /// Un élément ; `notFound` s'il a été supprimé (ou est dans la corbeille de Zotero).
    public func item(_ key: String) async throws -> ZoteroItem {
        let r = try await send(ZoteroRequest("GET", "/users/0/items/\(key)", query: [URLQueryItem(name: "format", value: "json")]))
        try check(r)
        guard let json = try JSONSerialization.jsonObject(with: r.data) as? [String: Any],
              let item = ZoteroItem(json: json) else { throw ZoteroError.failed(r.status, "réponse illisible") }
        if item.deleted { throw ZoteroError.notFound }
        return item
    }

    /// Crée un élément ; rend sa clé et sa version.
    public func create(_ object: [String: Any], key: String, serverID: String) async throws -> (key: String, version: Int) {
        let body = try JSONSerialization.data(withJSONObject: [object])
        let r = try await send(ZoteroRequest("POST", "/users/0/items",
                                             headers: ["Zotero-API-Key": key, "Zotero-Server-ID": serverID], body: body))
        try check(r)
        return try Self.created(r)
    }

    /// Remplace le texte d'une note ; rend la nouvelle version.
    public func updateNote(_ itemKey: String, html: String, version: Int, key: String, serverID: String) async throws -> Int {
        let body = try JSONSerialization.data(withJSONObject: ["note": html])
        let r = try await send(ZoteroRequest("PATCH", "/users/0/items/\(itemKey)", headers: [
            "Zotero-API-Key": key, "Zotero-Server-ID": serverID, "If-Unmodified-Since-Version": String(version),
        ], body: body))
        try check(r)
        return r.header("Last-Modified-Version").flatMap(Int.init) ?? version + 1
    }

    // MARK: - Réponses

    func send(_ request: ZoteroRequest) async throws -> ZoteroResponse { try await transport(request) }

    func check(_ r: ZoteroResponse) throws {
        switch r.status {
        case 200..<300: return
        case 401: throw ZoteroError.unauthorized
        case 403:
            let text = String(decoding: r.data, as: UTF8.self)
            if text.localizedCaseInsensitiveContains("not enabled") { throw ZoteroError.localAPIDisabled }
            if text.contains("denied") { throw ZoteroError.denied }
            throw ZoteroError.failed(403, text.trimmingCharacters(in: .whitespacesAndNewlines))
        case 404: throw ZoteroError.notFound
        case 412: throw ZoteroError.conflict
        case 429: throw ZoteroError.tooManyRequests
        default:
            throw ZoteroError.failed(r.status, String(decoding: r.data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Clé de l'élément créé : `successful` (objet complet) ou `success` (clé seule), selon la version de Zotero.
    static func created(_ r: ZoteroResponse) throws -> (key: String, version: Int) {
        let json = try JSONSerialization.jsonObject(with: r.data) as? [String: Any] ?? [:]
        let version = r.header("Last-Modified-Version").flatMap(Int.init)
        if let ok = (json["successful"] as? [String: Any])?["0"] as? [String: Any], let key = ok["key"] as? String {
            return (key, ok["version"] as? Int ?? version ?? 0)
        }
        if let key = (json["success"] as? [String: Any])?["0"] as? String { return (key, version ?? 0) }
        let failure = ((json["failed"] as? [String: Any])?["0"] as? [String: Any])?["message"] as? String
        throw ZoteroError.failed(r.status, failure ?? "élément non créé")
    }

    /// Message compréhensible pour une erreur Zotero ou réseau.
    public static func describe(_ error: any Error) -> String {
        (error as? ZoteroError)?.errorDescription ?? error.localizedDescription
    }
}
