import Foundation
import Testing
@testable import AlexandrieCore

@Suite struct StorageMaintenanceTests {
    @Test func purgesOrphansAndStaleConversions() throws {
        let lib = SampleLibrary()
        let directories = AppDirectories(base: tempDirectory())
        var book = try lib.index("Candide.epub")
        let covers = CoverStore(directory: directories.covers)

        let stale = KindleTransfer.cachedCopy(of: book, directories: directories)
        book.title = "Candide corrigé"
        let current = KindleTransfer.cachedCopy(of: book, directories: directories)
        let epub = KindleTransfer.exportedEPUB(of: book, directories: directories)
        let cover = covers.url(for: book.fingerprint)
        let orphanCover = covers.url(for: "disparu-123")
        let orphanConversion = directories.conversions.appendingPathComponent("disparu-123-abcd1234.azw3")
        for url in [stale, current, epub, cover, orphanCover, orphanConversion] {
            try Data(repeating: 1, count: 10).write(to: url)
        }
        #expect(stale != current)

        let report = StorageMaintenance.purge(keeping: [book], directories: directories)
        #expect(report == .init(removedFiles: 3, freedBytes: 30))
        for url in [current, epub, cover] { #expect(FileManager.default.fileExists(atPath: url.path)) }
        for url in [stale, orphanCover, orphanConversion] { #expect(!FileManager.default.fileExists(atPath: url.path)) }
        #expect(StorageMaintenance.size(of: directories.conversions) == 20)

        StorageMaintenance.clear(directories.conversions)
        #expect(StorageMaintenance.size(of: directories.conversions) == 0)
        #expect(FileManager.default.fileExists(atPath: cover.path))
    }
}
