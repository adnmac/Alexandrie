import Foundation
import Testing
@testable import FolunaCore

/// Fichiers abîmés (téléchargement coupé, disque plein) ou fabriqués : la lecture échoue proprement, sans planter.
@Suite struct RobustnessTests {
    func truncations(of data: Data) -> [Data] {
        var cuts = Set([0, 1, 4, 16, 64, 78, 100, 256, 1024, data.count / 3, data.count / 2, data.count - 1])
        cuts = cuts.filter { $0 >= 0 && $0 < data.count }
        return cuts.sorted().map { data.prefix($0) }
    }

    /// Octets pris au hasard (graine fixe) dans tout le fichier : en-têtes et tables incohérents.
    func corruptions(of data: Data, count: Int = 40) -> [Data] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(max(data.count, 1)))
        }
        return (0..<count).map { _ in
            var copy = data
            for _ in 0..<8 { copy[next()] = UInt8(truncatingIfNeeded: next()) }
            return copy
        }
    }

    @Test func damagedMobiAndAZW3DoNotCrash() throws {
        let epub = try makeSampleEPUB(chapters: 2, paragraphs: 5)
        let azw3 = tempDirectory().appendingPathComponent("livre.azw3")
        _ = try EPUBToAZW3.convert(input: epub, output: azw3)
        let data = try Data(contentsOf: azw3)
        for sample in truncations(of: data) + corruptions(of: data) {
            let url = tempDirectory().appendingPathComponent("abime.azw3")
            try sample.write(to: url)
            _ = try? MobiBook(data: sample)
            _ = try? MobiToEPUB.convert(input: url, output: tempDirectory().appendingPathComponent("sortie.epub"))
        }
    }

    @Test func damagedEPUBDoesNotCrash() throws {
        let data = try Data(contentsOf: try makeSampleEPUB(chapters: 2, paragraphs: 5))
        for sample in truncations(of: data) + corruptions(of: data) {
            let url = tempDirectory().appendingPathComponent("abime.epub")
            try sample.write(to: url)
            if let epub = try? EPUBReader(url: url) {
                _ = epub.tableOfContents()
                for item in epub.spine { _ = try? epub.data(item.path) }
            }
        }
    }
}
