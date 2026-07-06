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

    /// Full Disk Access only takes effect on the next launch, so quit and let
    /// a detached shell reopen the app once we're gone.
    static func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(Bundle.main.bundlePath)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openSystemPreferences() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
