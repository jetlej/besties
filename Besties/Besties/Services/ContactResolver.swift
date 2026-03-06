import Foundation
import SQLite3

final class ContactResolver {
    private var phoneLookup: [String: String] = [:]
    private var emailLookup: [String: String] = [:]
    private var loaded = false

    func loadContacts() {
        guard !loaded else { return }
        loaded = true

        let abDir = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        let fm = FileManager.default

        var dbPaths = [abDir + "/AddressBook-v22.abcddb"]
        if let sources = try? fm.contentsOfDirectory(atPath: abDir + "/Sources") {
            for source in sources {
                dbPaths.append(abDir + "/Sources/\(source)/AddressBook-v22.abcddb")
            }
        }

        for path in dbPaths {
            guard fm.fileExists(atPath: path) else { continue }
            loadFromDatabase(path: path)
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

            let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
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

            let name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty, !email.isEmpty else { continue }

            emailLookup[email.lowercased()] = name
        }
    }
}
