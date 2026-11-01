import Foundation
import SQLite3
import Contacts

/// A named contact card with a phone number and the day it was added — for
/// Reconnect's "Never followed up".
struct AddedContact {
    let name: String
    let phones: [String]
    let added: Date
    /// The card's note, else its company — often where you met.
    let detail: String?
}

final class ContactResolver {
    private var phoneLookup: [String: String] = [:]
    private var emailLookup: [String: String] = [:]
    private var phoneToImage: [String: Data] = [:]
    private var emailToImage: [String: Data] = [:]
    private var loaded = false

    /// Screenshot mode drops every surname so marketing captures show first
    /// names only, never a real person's full name. Enable with
    /// `defaults write com.besties.app screenshotMode -bool true`, then relaunch.
    /// Debug builds only — Release builds always show full names.
    #if DEBUG
    static let isScreenshotMode = UserDefaults.standard.bool(forKey: "screenshotMode")
    #else
    static let isScreenshotMode = false
    #endif

    private static let givenNamePool = [
        "Adrian", "Bianca", "Camille", "Dorian", "Elena", "Felix",
        "Greta", "Hugo", "Iris", "Julian", "Kira", "Lorenzo",
        "Mira", "Nadia", "Oscar", "Priya", "Rafael", "Simone",
        "Theo", "Vera",
    ]

    /// Stable FNV-1a over `text`. Swift's own `hashValue` is seeded per process
    /// and would drift between runs, so the same person would look like a
    /// different person in each capture.
    private static func stableHash(_ text: some StringProtocol) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Keeps the given name and drops everything after it.
    static func screenshotName(_ name: String) -> String {
        guard isScreenshotMode, let space = name.firstIndex(of: " ") else { return name }
        return String(name[..<space])
    }

    /// A stand-in name for a handle that never resolved to a contact card, so
    /// screenshots never show a raw phone number or email address.
    static func screenshotPlaceholder(forHandle handle: String) -> String {
        givenNamePool[Int(stableHash(handle) % UInt64(givenNamePool.count))]
    }

    func loadContacts() {
        guard !loaded else { return }
        loaded = true

        for path in Self.databasePaths() {
            loadFromDatabase(path: path)
        }

        loadContactImages()
    }

    /// The local database plus one per synced account (iCloud, Google, …).
    private static func databasePaths() -> [String] {
        let abDir = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        let fm = FileManager.default
        var paths = [abDir + "/AddressBook-v22.abcddb"]
        if let sources = try? fm.contentsOfDirectory(atPath: abDir + "/Sources") {
            for source in sources {
                paths.append(abDir + "/Sources/\(source)/AddressBook-v22.abcddb")
            }
        }
        return paths.filter { fm.fileExists(atPath: $0) }
    }

    /// Days on which more than this many cards were "added" are bulk imports.
    private static let bulkImportThreshold = 50

    /// Every named card with a phone number, with the day it was added. The
    /// same person in two accounts is one entry (earliest date). Cards from a
    /// bulk import are dropped: an iCloud migration stamps hundreds of cards
    /// with one day, which says nothing about when you met.
    func addedContacts() -> [AddedContact] {
        struct Card { var phones: Set<String>; var added: Date; var detail: String? }
        var byName: [String: Card] = [:]

        for path in Self.databasePaths() {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }
            let sql = """
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION, r.ZCREATIONDATE, n.ZTEXT, p.ZFULLNUMBER
                FROM ZABCDRECORD r
                JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
                LEFT JOIN ZABCDNOTE n ON n.ZCONTACT = r.Z_PK
                WHERE r.ZCREATIONDATE IS NOT NULL AND p.ZFULLNUMBER IS NOT NULL
                  AND (r.ZFIRSTNAME IS NOT NULL OR r.ZLASTNAME IS NOT NULL)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } }
                let name = Self.screenshotName([text(0), text(1)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
                guard !name.isEmpty, let phone = text(5) else { continue }
                // Core Data timestamps count seconds from 2001-01-01.
                let added = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 3))
                let note = text(4)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = (note?.isEmpty == false ? note : nil) ?? text(2)
                var card = byName[name] ?? Card(phones: [], added: added, detail: detail)
                card.phones.insert(phone)
                card.added = min(card.added, added)
                if card.detail == nil { card.detail = detail }
                byName[name] = card
            }
        }

        let calendar = Calendar.current
        let perDay = Dictionary(grouping: byName.values, by: { calendar.startOfDay(for: $0.added) }).mapValues(\.count)
        return byName.compactMap { name, card in
            guard perDay[calendar.startOfDay(for: card.added), default: 0] <= Self.bulkImportThreshold else { return nil }
            return AddedContact(name: name, phones: card.phones.sorted(), added: card.added, detail: card.detail)
        }
    }

    /// Photos are keyed by handle (phone/email), not name, so two contacts
    /// who share a display name each resolve to their own photo.
    func imageData(forHandle handle: String) -> Data? {
        let digits = handle.filter(\.isNumber)
        if digits.count >= 7, let data = phoneToImage[String(digits.suffix(10))] {
            return data
        }
        if let data = emailToImage[handle.lowercased()] {
            return data
        }
        return nil
    }

    /// Thumbnails come from the Contacts framework, which prompts for
    /// Contacts access the first time. Denied access just means no photos.
    private func loadContactImages() {
        let store = CNContactStore()
        var granted = CNContactStore.authorizationStatus(for: .contacts) == .authorized

        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            store.requestAccess(for: .contacts) { ok, _ in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
        }
        guard granted else { return }

        let keys = [
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactThumbnailImageDataKey,
        ] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)

        try? store.enumerateContacts(with: request) { contact, _ in
            guard let data = contact.thumbnailImageData else { return }
            for phone in contact.phoneNumbers {
                let digits = phone.value.stringValue.filter(\.isNumber)
                if digits.count >= 7 {
                    self.phoneToImage[String(digits.suffix(10))] = data
                }
            }
            for email in contact.emailAddresses {
                let address = (email.value as String).lowercased()
                if !address.isEmpty {
                    self.emailToImage[address] = data
                }
            }
        }
    }

    func resolve(handle: String) -> String? {
        let digits = handle.filter(\.isNumber)
        if digits.count >= 7, let name = phoneLookup[String(digits.suffix(10))] {
            return name
        }
        if let name = emailLookup[handle.lowercased()] {
            return name
        }
        return nil
    }

    private func loadFromDatabase(path: String) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        loadPhoneNumbers(db: db!)
        loadEmails(db: db!)
    }

    private func loadPhoneNumbers(db: OpaquePointer) {
        let sql = """
            SELECT r.ZFIRSTNAME, r.ZLASTNAME, p.ZFULLNUMBER
            FROM ZABCDRECORD r
            JOIN ZABCDPHONENUMBER p ON p.ZOWNER = r.Z_PK
            WHERE p.ZFULLNUMBER IS NOT NULL
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let first = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let last = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let phone = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""

            let name = Self.screenshotName([first, last].filter { !$0.isEmpty }.joined(separator: " "))
            guard !name.isEmpty else { continue }

            let digits = phone.filter(\.isNumber)
            if digits.count >= 7 {
                phoneLookup[String(digits.suffix(10))] = name
            }
        }
    }

    private func loadEmails(db: OpaquePointer) {
        let sql = """
            SELECT r.ZFIRSTNAME, r.ZLASTNAME, e.ZADDRESS
            FROM ZABCDRECORD r
            JOIN ZABCDEMAILADDRESS e ON e.ZOWNER = r.Z_PK
            WHERE e.ZADDRESS IS NOT NULL
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let first = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let last = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let email = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""

            let name = Self.screenshotName([first, last].filter { !$0.isEmpty }.joined(separator: " "))
            guard !name.isEmpty, !email.isEmpty else { continue }

            emailLookup[email.lowercased()] = name
        }
    }
}
