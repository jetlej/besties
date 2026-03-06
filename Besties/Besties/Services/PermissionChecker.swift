import Foundation
import AppKit
import SQLite3

enum PermissionChecker {
    private static let chatDBPath: String = {
        NSHomeDirectory() + "/Library/Messages/chat.db"
    }()

    static func hasFullDiskAccess() -> Bool {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(chatDBPath, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }

        guard result == SQLITE_OK else { return false }

        var stmt: OpaquePointer?
        let ok = sqlite3_prepare_v2(db, "SELECT 1 FROM message LIMIT 1", -1, &stmt, nil) == SQLITE_OK
        sqlite3_finalize(stmt)
        return ok
    }

    static func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
