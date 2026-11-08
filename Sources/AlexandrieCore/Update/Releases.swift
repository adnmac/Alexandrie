import Foundation
import Security

/// Version publiée sur GitHub (scripts/release.sh).
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var notes: String
    /// Image disque de l'app signée (Alexandrie-X.Y.Z.dmg), sinon son archive (.zip, anciennes versions).
    public var downloadURL: URL
    public var pageURL: URL?

    public var isDiskImage: Bool { downloadURL.pathExtension.lowercased() == "dmg" }
}

extension UpdateChecker {
    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Dernière version publiée, si elle est plus récente que `currentVersion` ; nil sinon (ou si aucune n'est publiée).
    public func newerRelease(than currentVersion: String) async throws -> ReleaseInfo? {
        guard let release = Self.parseRelease(try await fetch(Self.latestReleaseURL)),
              Self.isVersion(release.version, newerThan: currentVersion) else { return nil }
        return release
    }

    static func parseRelease(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = Self.asset(in: assets, suffix: ".dmg") ?? Self.asset(in: assets, suffix: ".zip"),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return ReleaseInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                           notes: json["body"] as? String ?? "",
                           downloadURL: url,
                           pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)))
    }

    static func asset(in assets: [[String: Any]], suffix: String) -> [String: Any]? {
        assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(suffix) == true }
    }

    /// Comparaison numérique « 0.10.0 » > « 0.9.2 ».
    public static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let (x, y) = (i < pa.count ? pa[i] : 0, i < pb.count ? pb[i] : 0)
            if x != y { return x > y }
        }
        return false
    }
}

/// Vérifie qu'une app téléchargée porte la même signature que l'app en cours (même certificat) avant de l'installer.
public enum SignatureCheck {
    public enum Failure: LocalizedError {
        case runningAppNotSigned
        case mismatch(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .runningAppNotSigned:
                String(localized: "Cette copie d'Alexandrie n'est pas signée avec le certificat stable : installez cette version à la main une fois, les suivantes s'installeront d'elles-mêmes.")
            case .mismatch(let status):
                String(localized: "La version téléchargée ne porte pas la signature attendue (\(status)) : elle n'a pas été installée.")
            }
        }
    }

    /// Lève une erreur si `app` n'est pas signée par le même certificat que l'app en cours d'exécution.
    public static func verifySameSigner(_ app: URL) throws {
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic else {
            throw Failure.runningAppNotSigned
        }
        if isAdHoc(runningStatic) { throw Failure.runningAppNotSigned }
        guard SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure.runningAppNotSigned
        }
        var candidate: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(app as CFURL, [], &candidate)
        guard created == errSecSuccess, let candidate else { throw Failure.mismatch(created) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(candidate, flags, requirement)
        guard status == errSecSuccess else { throw Failure.mismatch(status) }
    }

    static func isAdHoc(_ code: SecStaticCode) -> Bool {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return true }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}
