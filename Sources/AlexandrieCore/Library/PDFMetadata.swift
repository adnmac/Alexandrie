import AppKit
import Foundation
import PDFKit

enum PDFMetadata {
    static func extract(from url: URL) throws -> BookMetadata {
        guard let doc = PDFDocument(url: url) else {
            throw BookError.unreadable("PDF invalide")
        }
        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String) ?? ""
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String) ?? ""
        var meta = BookMetadata(
            title: title,
            authors: author.split(whereSeparator: { $0 == ";" || $0 == "&" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        meta.subjects = (attrs[PDFDocumentAttribute.keywordsAttribute] as? [String]) ?? []
        meta.isDRMProtected = doc.isEncrypted && doc.isLocked
        if let page = doc.page(at: 0) {
            let thumb = page.thumbnail(of: NSSize(width: 600, height: 900), for: .mediaBox)
            meta.coverData = ImageTools.jpegData(thumb)
        }
        return meta
    }
}
