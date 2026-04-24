import Foundation

enum Recents {
    private static let key = "launcher.recents"
    private static let max = 20

    static func load() -> [String] {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        // Prune paths that no longer exist — stops stale entries ranking forever.
        let fm = FileManager.default
        let valid = raw.filter { fm.fileExists(atPath: $0) }
        if valid.count != raw.count {
            UserDefaults.standard.set(valid, forKey: key)
        }
        return valid
    }

    static func record(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > max { list = Array(list.prefix(max)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func forget(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        UserDefaults.standard.set(list, forKey: key)
    }
}
