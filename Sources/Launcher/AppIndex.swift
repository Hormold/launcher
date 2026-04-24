import Foundation
import AppKit
import CoreServices

struct AppEntry: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    /// All searchable aliases: file name + CFBundleDisplayName + CFBundleName (deduped).
    /// Always lowercased. Older caches without this field default to [name.lowercased()].
    let aliases: [String]

    var url: URL { URL(fileURLWithPath: path) }

    init(path: String, name: String, aliases: [String] = []) {
        self.path = path
        self.name = name
        var a = aliases.map { $0.lowercased() }
        if a.isEmpty { a = [name.lowercased()] }
        self.aliases = Array(NSOrderedSet(array: a)) as! [String]
    }

    enum CodingKeys: String, CodingKey { case path, name, aliases }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try c.decode(String.self, forKey: .path)
        self.name = try c.decode(String.self, forKey: .name)
        let a = (try? c.decode([String].self, forKey: .aliases)) ?? [name.lowercased()]
        self.aliases = a
    }
}

/// `AppEntry` plus pre-computed byte arrays for fast search.
/// Building these once at index time turns scoring into byte-level loops
/// instead of repeated grapheme-aware String ops.
struct IndexedApp {
    let app: AppEntry
    /// Lowercased UTF-8 bytes for each alias.
    let aliasBytes: [[UInt8]]
    /// Words of each alias (split by non-alnum), as UTF-8 byte arrays.
    let aliasWords: [[[UInt8]]]

    init(_ app: AppEntry) {
        self.app = app
        self.aliasBytes = app.aliases.map { Array($0.utf8) }
        self.aliasWords = app.aliases.map { alias in
            alias.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map { Array($0.utf8) }
        }
    }
}

final class AppIndex: ObservableObject {
    static let shared = AppIndex()

    @Published private(set) var apps: [AppEntry] = []
    @Published private(set) var indexed: [IndexedApp] = []
    @Published private(set) var isReady: Bool = false

    private let searchRoots: [String] = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSString(string: "~/Applications").expandingTildeInPath,
        "/Applications/Utilities",
        "/Applications/Setapp",
        "/System/Library/CoreServices/Applications",
    ]

    /// Hardcoded roots for specific system apps that live outside scannable dirs.
    private let explicitApps: [String] = [
        "/System/Library/CoreServices/Finder.app",
    ]

    private let cacheURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Launcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }()

    private let iconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 500
        return c
    }()
    private let queue = DispatchQueue(label: "launcher.index", qos: .userInitiated)
    private var fsWatcher: FSWatcher?
    private var refreshDebounceItem: DispatchWorkItem?

    func loadCachedThenRefresh() {
        if let cached = readCache(), !cached.isEmpty {
            let valid = cached.filter { FileManager.default.fileExists(atPath: $0.path) }
            let prebuilt = valid.map(IndexedApp.init)
            DispatchQueue.main.async {
                self.apps = valid
                self.indexed = prebuilt
                self.isReady = true
            }
        }
        refresh()
        startFSWatcher()
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.scanAll()
            let prebuilt = found.map(IndexedApp.init)
            DispatchQueue.main.async {
                self.apps = found
                self.indexed = prebuilt
                self.isReady = true
            }
            self.writeCache(found)
        }
    }

    /// Called on user action. Verifies the app still exists; if gone, removes it
    /// from the index and returns false. Caller should swallow the "not found".
    @discardableResult
    func open(_ entry: AppEntry) -> Bool {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            removeStale(path: entry.path)
            return false
        }
        NSWorkspace.shared.open(entry.url)
        return true
    }

    func icon(for entry: AppEntry) -> NSImage {
        if let cached = iconCache.object(forKey: entry.path as NSString) { return cached }
        let img = NSWorkspace.shared.icon(forFile: entry.path)
        img.size = NSSize(width: 32, height: 32)
        iconCache.setObject(img, forKey: entry.path as NSString)
        return img
    }

    private func removeStale(path: String) {
        DispatchQueue.main.async {
            self.apps.removeAll { $0.path == path }
        }
        iconCache.removeObject(forKey: path as NSString)
        // Persist async.
        queue.async { [weak self] in
            guard let self else { return }
            let remaining = self.apps.filter { $0.path != path }
            self.writeCache(remaining)
        }
    }

    // MARK: - FSEvents

    private func startFSWatcher() {
        let roots = searchRoots.filter { FileManager.default.fileExists(atPath: $0) }
        fsWatcher = FSWatcher(paths: roots) { [weak self] in
            self?.debouncedRefresh()
        }
        fsWatcher?.start()
    }

    private func debouncedRefresh() {
        refreshDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshDebounceItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    // MARK: - scan

    func scanSync() -> [AppEntry] { scanAll() }

    private func scanAll() -> [AppEntry] {
        var seen = Set<String>()
        var result: [AppEntry] = []
        for root in searchRoots {
            scan(root: root, depth: 0, seen: &seen, result: &result)
        }
        // Explicit system apps outside normal roots (Finder lives in CoreServices).
        for path in explicitApps {
            let key = ((path as NSString).standardizingPath)
            if FileManager.default.fileExists(atPath: path), seen.insert(key).inserted,
               let entry = makeEntryForced(path: path) {
                result.append(entry)
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return result
    }

    private func scan(root: String, depth: Int, seen: inout Set<String>, result: inout [AppEntry]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: root) else { return }
        for item in items {
            let full = (root as NSString).appendingPathComponent(item)
            // Resolve symlinks for dedup (brew --cask, Setapp stubs, etc.)
            let resolved = (try? fm.destinationOfSymbolicLink(atPath: full)).map { link in
                link.hasPrefix("/") ? link : (root as NSString).appendingPathComponent(link)
            } ?? full

            if item.hasSuffix(".app") {
                let key = (resolved as NSString).standardizingPath
                if seen.insert(key).inserted {
                    if let entry = makeEntry(path: full) {
                        result.append(entry)
                    }
                }
            } else if depth < 2 {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    if full.hasSuffix(".app/Contents") { continue }
                    scan(root: full, depth: depth + 1, seen: &seen, result: &result)
                }
            }
        }
    }

    private func makeEntry(path: String) -> AppEntry? {
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var aliases: [String] = [fileName]

        // Extract real names from bundle Info.plist, and filter out background services.
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            // Skip apps that don't want to appear in Dock/Cmd-Tab (agents, helpers, daemons).
            if (plist["LSUIElement"] as? Bool) == true { return nil }
            if (plist["LSUIElement"] as? String) == "1" { return nil }
            if (plist["LSBackgroundOnly"] as? Bool) == true { return nil }
            if (plist["LSBackgroundOnly"] as? String) == "1" { return nil }

            if let display = plist["CFBundleDisplayName"] as? String, !display.isEmpty {
                aliases.append(display)
            }
            if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                aliases.append(bundleName)
            }
        }
        // Primary display name: first alias (usually file name, which users recognize).
        return AppEntry(path: path, name: aliases.first ?? fileName, aliases: aliases)
    }

    /// Version of makeEntry used for explicit apps — skips LSUIElement filter
    /// because Finder technically has LSUIElement=true but we always want it.
    private func makeEntryForced(path: String) -> AppEntry? {
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var aliases: [String] = [fileName]
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let display = plist["CFBundleDisplayName"] as? String, !display.isEmpty {
                aliases.append(display)
            }
            if let bundleName = plist["CFBundleName"] as? String, !bundleName.isEmpty {
                aliases.append(bundleName)
            }
        }
        return AppEntry(path: path, name: aliases.first ?? fileName, aliases: aliases)
    }

    // MARK: - cache

    private func readCache() -> [AppEntry]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        do {
            return try JSONDecoder().decode([AppEntry].self, from: data)
        } catch {
            // Corrupt cache — delete and rescan.
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
    }

    private func writeCache(_ entries: [AppEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
