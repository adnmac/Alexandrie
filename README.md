# Foluna

A book library for macOS that loads your books onto your e-reader (Kindle, Kobo, or any USB e-reader that reads EPUB) **over a USB cable**, without Calibre.

Website: [foluna.app](https://foluna.app) · Download: [latest release](https://github.com/adnmac/Foluna/releases/latest) · Contact: info@foluna.app

Requires macOS 14 Sonoma or later on a Mac with Apple silicon. Free and open source under the MIT licence.

## Features

- Indexes one or more existing book folders (EPUB, MOBI, AZW3, AZW, PDF, and PRC, FB2, CBZ) **without ever modifying them**; a folder on an unplugged disk keeps its books, shown as unavailable until the disk is back.
- Reads title, authors, language, publisher, summary and cover; search, sorting, filters by format and author.
- Title, authors, publisher, publication date, ISBN, language, summary and tags can be corrected in the app;
  corrections are applied to the copies sent to the Kindle (the source file stays untouched).
- Direct correction of a book already on the Kindle (MOBI/AZW3 without DRM): only the file's metadata is rewritten.
- Online check of new books against the **BnF** (French National Library), then **Open Library** (by ISBN, or by title and author):
  differences are suggested in the book's details and nothing changes without your approval. A “To Review” filter sits in the sidebar.
- Sending to the Kindle: direct copy of MOBI/AZW3/PDF, **automatic EPUB → AZW3 conversion** (the Kindle does not read EPUB over USB), with a cover thumbnail.
- **Reading window** (⌘L or double-click) for EPUB, MOBI, AZW3 and PDF: keyboard page turns, table of contents, resumes where you stopped (“% read” in the book's details), text size, an “Aa” menu with the font (the book's own, or a macOS font with or without serifs: New York, Charter, Iowan Old Style, Georgia, Avenir Next…) and light, sepia or dark pages, highlights (⇧⌘H) stored with the Kindle's in “Notes and Highlights”, from where they reopen the reading window at their passage, and their notes (click the highlighted passage) and colours, editable on both sides. Topics (“Road renovation”, a thesis) group highlights, a passage can belong to several, and they name their colours (yellow = construction); the reading window picks the book's topic, notes can be filtered by colour and topic, and each topic has its own sidebar page: all its notes from every book, sorted by named colour, by book or by date, and exported to Markdown in that order.
- **Search inside books**: the search field looks in titles, authors… or in the text of the books (EPUB, MOBI, AZW3, PDF), indexed in the background, one file per book, with an “Exact Spelling” option (case and accents); each matching book shows its excerpts, and an excerpt opens the reading window at the passage, with the list of matches in the left column and ⌘G / ⇧⌘G to move between them.
- PDF: as is, **with cropped margins** (the text looks bigger) or as **resizable text** (text extracted to AZW3, chapters taken from the PDF's outline); the original is never modified.
- **MOBI/AZW3 → EPUB conversion** (KF7, KF8 and hybrid files).
- **More formats**, each one can be turned off in Settings › Formats (its books stay in the library, neither read nor sent):
  **PRC** (old Mobipocket books, read like a MOBI), **FictionBook** (`.fb2`, `.fb2.zip`) and **plain text** (`.txt`, with
  the Project Gutenberg header read and chapters found by their titles), converted to EPUB, or to AZW3 for the Kindle;
  **comics** (`.cbz`, one image per page, `ComicInfo.xml` read), sent as is to the Kobo and as a PDF to the Kindle.
  TXT files are added only by import or drag and drop, never by scanning a book folder (too many README files).
  FB2, CBZ and TXT are read by importers (`Sources/AlexandrieCore/Import/`) with limits on file, archive and image sizes.
- **Zotero**: “Send to Zotero” (Export menu of a book's or a topic's notes) copies passages, notes, colours and locations into a note attached to the book's item, found by ISBN or title and author, or created from the book's details. Sending again updates the note, without duplicates; a topic gives one note per book. Notes stay in Foluna: changes made in Zotero do not come back. Requires Zotero 10 or later, open, with Settings › Advanced › “Allow other applications on this computer to communicate with Zotero”, and “Always Allow” on the first send.
- **Online catalogues (OPDS)**: Project Gutenberg, Ebooks libres et gratuits and the Bibliothèque numérique romande are offered in the sidebar; you can add the address of any public OPDS 1.2 catalogue (https, no account). Browse its sections, search it from the search field (Return key), keep only books in one language with the “Language” menu (at Gutenberg, searches and lists are filtered by the server), and “Download” adds the book to the library like an import; it is then sent to the e-reader from its details. Paid or DRM-protected books are skipped.
- Kindle as a **USB disk** (models up to 2023) and over **MTP** (models from late 2024, via libmtp).
- **Kobo** (USB disk, recognised automatically): EPUB files are sent as is, with your corrections written into the file; MOBI and AZW3 are converted to EPUB, and PDF follows its mode. Its highlights and notes (the `KoboReader.sqlite` database, read from a copy) join “Notes and Highlights”.
- **Other USB e-readers** that read EPUB (PocketBook, Tolino…): Settings › E-Readers › “Add a USB E-Reader…”, with the folder where books go; it is then recognised every time it is plugged in. Its notes are not read.

## Languages

The interface is available in English, French, Dutch, German and Spanish. It follows the macOS language
(or the one chosen for Foluna in System Settings › General › Language & Region › Applications), and Settings › General ›
Language changes it in the app (applied after a restart). Markdown exports, notes sent to Zotero, notifications and the
Shortcuts action follow this language; titles, notes and dates already saved stay as they are. Translations live in
`Resources/Localizable.xcstrings` (see `scripts/l10n.sh` and `docs/l10n-glossaire.md`); the Dutch, German and Spanish
translations would benefit from a review by native speakers.

## Build and run

```bash
scripts/bundle.sh               # builds build/Foluna.app (release) and copies it to ~/Applications
open build/Foluna.app
```

Other scripts: `scripts/build.sh [release]`, `scripts/test.sh`, `scripts/selftest.sh` (the app's self-test on test data in `/tmp`), `scripts/snap.sh` (screenshots of every page in light and dark mode, with sample books).

Internal names (Swift targets `Alexandrie` and `AlexandrieCore`, the executable, `ALEXANDRIE_*` environment variables,
the bundle identifier `be.adnmac.alexandrie` and the data folder) keep the project's original code name, because
permissions, settings, the Keychain and update checks depend on them.

### Signing and releases

`scripts/bundle.sh` signs the app with an **Apple Development** certificate if there is one (free: Xcode › Settings ›
Accounts › your Apple Account › Manage Certificates › + › Apple Development; the keychain must also hold the
[Apple WWDR G3](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer) intermediate certificate).
The Shortcuts action only runs with this certificate, which carries a team ID.
Otherwise it uses a self-signed code-signing certificate named “Alexandrie Dev” (Keychain Access › Certificate Assistant ›
Create a Certificate: self-signed root, code signing).
With a stable signature, macOS keeps the app's permissions (the Kindle's disk…) from one version to the next;
without a certificate, the signature is ad hoc.

`scripts/release.sh X.Y.Z` publishes a release on GitHub: a `Foluna-X.Y.Z.dmg` disk image (the signed app and
a link to Applications) and a `.zip` archive for older versions. The installed app reports it and offers
“Install and Relaunch”: it downloads the `.dmg`, extracts the app, checks that it carries the same signature,
then quits; a script then replaces the app (the old one comes back if the copy fails) and relaunches it.
The `.dmg` can also be installed by hand from the release page (drag Foluna to Applications).
With only the Command Line Tools, these scripts load the SwiftUI and Swift Testing macro plugins
from `/Applications/Xcode.app` (Xcode must be installed, but its licence does not need to be accepted).

### Recent Kindles (MTP)

```bash
brew install libmtp
```

libmtp is loaded at run time: without it, the app works with “USB disk” Kindles only.
Quit Android File Transfer (or any MTP tool) before plugging in the Kindle.

## Data

Everything the app produces is in `~/Library/Application Support/Alexandrie/`:

| Item | Purpose |
|---|---|
| `library.json` | library index |
| `library.formats.json` | index of the books in formats added after version 0.6.0 (PRC, FB2, CBZ, TXT): kept apart so that `library.json` stays readable by 0.6.0 if you go back to it |
| `Covers/` | scaled-down covers |
| `Conversions/` | converted AZW3 and EPUB files (cache) |
| `Imports/` | books added by drag and drop, “Import”, or downloaded from an online catalogue |
| `opds.json` | added online catalogues, and books downloaded from them |
| `zotero.json` | Zotero items and notes linked to each book and topic |

**Copy off the Mac** (Settings › Backup): every day, Foluna copies its data files, imported or downloaded books
(`Imports/`) and covers into `Sauvegarde Foluna`, inside the chosen folder: iCloud Drive (offered if it is turned on)
or an external disk. The last 30 days are kept; an unplugged disk is reported and copying resumes when it is back.
“Restore…” relaunches the app on a dated copy: the previous state is set aside in `Sauvegardes/`, missing books come
back, and none is deleted. Caches (conversions, indexed text) and your own book folders are not copied.

Covers and conversions no longer in use are deleted after each rescan; the settings show the size of these caches
and can empty the conversions. An unreadable `library.json` is never overwritten: it is renamed
`library.corrupt-<date>.json` and the library is indexed again (edits remain in that file).

## Architecture

- `Sources/AlexandrieCore`: logic without UI (testable)
  - `EPUB/` EPUB reading (OPF, nav, NCX) and EPUB 3 writing
  - `Mobi/` PalmDB, MOBI/EXTH headers, PalmDoc, HUFF/CDIC, INDX/TAGX/CNCX indexes
  - `Conversion/` `MobiToEPUB` (inspired by KindleUnpack) and `EPUBToAZW3` (inspired by calibre's KF8 writer)
  - `Library/` scanner, fingerprints, covers, JSON index
  - `Kindle/` detection and transfer (mounted disk, MTP)
  - `Import/` importers for FB2, CBZ and TXT (`BookImporter`), converted through `ImportedDocument` (PRC is read by `Mobi/`)
- `Sources/CMTPShim`: C bridge to libmtp (dlopen)
- `Sources/Alexandrie`: SwiftUI app
  - `Views/` one view per file (`ContentView`: the main window; `Navigation`: sidebar pages)
  - `Services/` app state (`LibraryStore`, `KindleMonitor`, `UpdateMonitor`) and `BookCommands`, the commands on the
    selection shared by the menu bar and the self-test
  - `UI/` design system tokens (see `design/DESIGN-SYSTEM.md`)

Code comments and internal documents (`docs/`, `design/`) are written in French.

## Tests

```bash
scripts/test.sh
ALEXANDRIE_FIXTURES=/path/to/books scripts/test.sh   # + conversions on real files
```

## Limitations

- Kobo: books are sent as EPUB, not KEPUB (the Kobo's optimised format); highlight colours on colour Kobos are read according to an assumed mapping (yellow, pink, blue, green).
- Android e-readers (Boox) and reMarkable are not supported.
- DRM-protected books are neither converted nor unlocked (a purchased AZW3 can still be copied as is).
- The KFX format is not supported.
- EPUB → AZW3 conversion targets common books (text, images, CSS, table of contents); complex layouts may be less faithful than with Calibre.

## Privacy

Foluna is free, with no account, analytics or advertising. Everything stays on the Mac, in `~/Library/Application Support/Alexandrie/`, except two connections, which can be turned off in Settings › General, and the online catalogues:

- **Online check of books**, only after you agree (welcome screen or Settings): the ISBN, or else the title and author, is sent to the BnF catalogue, then to Open Library.
- **Update check**: the app asks GitHub for the latest release of this repository.
- **Online catalogues (OPDS)**: nothing is sent until a catalogue is opened in the sidebar; then the catalogue receives the pages browsed, the words searched and the books downloaded. A removed catalogue (“Manage Catalogs…”) is never contacted again.

Sending to Zotero stays on the Mac: Foluna writes to Zotero through its local API (`127.0.0.1`), only when you click “Send to Zotero”; Zotero then syncs the notes if you use its online account. The permission granted by Zotero is kept in the Keychain.

The copy off the Mac goes through no Foluna server: it writes to the chosen folder; in iCloud Drive, the user's own iCloud account syncs it.

Crash reports stay on the Mac; they are only sent if the user chooses to send them. Details are in `docs/AUDIT-PRODUCTION.md`, § 5.

## Licence

Foluna is free software, distributed under the [MIT licence](LICENSE). The BAMA skills in `.claude/skills/` are also under the MIT licence (see `.claude/skills/BAMA-COMMIT`).
