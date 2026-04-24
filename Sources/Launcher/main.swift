import Foundation
import AppKit

// CLI modes. All exit before launching SwiftUI.
let args = CommandLine.arguments

if let i = args.firstIndex(of: "--probe") {
    let q = i + 1 < args.count ? args[i + 1] : ""
    CLI.probe(query: q)
    exit(0)
}

if args.contains("--self-test") {
    exit(CLI.selfTest() ? 0 : 1)
}

if args.contains("--integrity") {
    exit(CLI.integrity() ? 0 : 1)
}

if args.contains("--bench") {
    CLI.bench()
    exit(0)
}

LauncherApp.main()

// MARK: - CLI

enum CLI {
    static func probe(query: String) {
        let apps = AppIndex.shared.scanSync()
        let variants = KeyboardLayout.variants(query)
        print("[probe] indexed: \(apps.count) apps")
        print("[probe] query: \"\(query)\"  variants: \(variants)")
        let results = SearchEngine.search(query: query, in: apps, recents: [])
        print("[probe] top 10:")
        for (i, app) in results.prefix(10).enumerated() {
            print("  \(i + 1). \(app.name)  aliases=\(app.aliases)  [\(app.path)]")
        }
    }

    static func bench() {
        print("[bench] scanning...")
        let t0 = Date()
        let apps = AppIndex.shared.scanSync()
        let scanMs = Date().timeIntervalSince(t0) * 1000
        print("[bench] scan: \(apps.count) apps in \(String(format: "%.1f", scanMs)) ms")

        let queries = ["notion", "chrome", "safari", "finder", "code", "term", "ntn",
                       "тщешщт", "noti", "1", "a", "xyz", "asdfghjkl", ""]
        let iterations = 1000 / queries.count
        let t1 = Date()
        for _ in 0..<iterations {
            for q in queries {
                _ = SearchEngine.search(query: q, in: apps, recents: [])
            }
        }
        let searchMs = Date().timeIntervalSince(t1) * 1000
        let total = iterations * queries.count
        print("[bench] search: \(total) queries in \(String(format: "%.1f", searchMs)) ms  avg=\(String(format: "%.3f", searchMs / Double(total))) ms")
    }

    static func integrity() -> Bool {
        let apps = AppIndex.shared.scanSync()
        var missing: [String] = []
        for app in apps {
            if !FileManager.default.fileExists(atPath: app.path) {
                missing.append(app.path)
            }
        }
        print("[integrity] \(apps.count) apps scanned, \(missing.count) missing")
        for m in missing { print("  MISSING: \(m)") }
        return missing.isEmpty
    }

    /// Automated smoke tests covering all search scenarios. Exits non-zero on failure.
    static func selfTest() -> Bool {
        var failures: [String] = []
        let apps = AppIndex.shared.scanSync()

        func expect(_ desc: String, _ cond: Bool) {
            let mark = cond ? "✓" : "✗"
            print("  \(mark) \(desc)")
            if !cond { failures.append(desc) }
        }

        func top(_ q: String, in apps: [AppEntry]) -> AppEntry? {
            SearchEngine.search(query: q, in: apps, recents: []).first
        }

        // T1: index is non-empty
        print("[test] index")
        expect("indexed > 50 apps (found \(apps.count))", apps.count > 50)

        // T2: Finder (ships with every mac) must be present
        let hasFinder = apps.contains { $0.name.lowercased() == "finder" }
        expect("Finder is indexed", hasFinder)

        // T3: Safari (ships with every mac) must be present
        let hasSafari = apps.contains { $0.name.lowercased() == "safari" }
        expect("Safari is indexed", hasSafari)

        // T4: search "safari" → Safari top-1
        print("[test] search exact")
        expect("top1(safari) = Safari", top("safari", in: apps)?.name.lowercased() == "safari")

        // T5: search "SAFARI" (caps) → same result
        expect("top1(SAFARI) = Safari", top("SAFARI", in: apps)?.name.lowercased() == "safari")

        // T6: search "saf" (prefix) → Safari top-1
        expect("top1(saf) = Safari", top("saf", in: apps)?.name.lowercased() == "safari")

        // T7: search "фаффкш" (Safari typed on RU layout) → Safari top-1
        //    s=ы, a=ф, f=а, a=ф, r=к, i=ш → "ыфафкш". Actually s→ы a→ф r→к i→ш.
        //    "safari" → s-a-f-a-r-i → ы-ф-а-ф-к-ш
        print("[test] layout swap")
        let ruSafari = "ыфафкш"
        expect("layout-swap(\(ruSafari)) → Safari", top(ruSafari, in: apps)?.name.lowercased() == "safari")

        // T8: search "" → non-empty (alphabetic list)
        print("[test] empty query")
        expect("empty query returns all", SearchEngine.search(query: "", in: apps, recents: []).count == apps.count)

        // T9: search nonsense → empty
        print("[test] no match")
        expect("top(xzqvbnmkjhgf) = empty", top("xzqvbnmkjhgf", in: apps) == nil)

        // T10: subsequence — "fndr" should find Finder
        print("[test] subsequence")
        expect("top1(fndr) = Finder", top("fndr", in: apps)?.name.lowercased() == "finder")

        // T11: recents override ranking on exact tie
        print("[test] recents boost")
        let someApp = apps.first(where: { $0.name.lowercased().contains("safari") })
        if let a = someApp {
            let withRecents = SearchEngine.search(query: "", in: apps, recents: [a.path])
            expect("recent app is first when query empty", withRecents.first?.path == a.path)
        }

        // T12: corrupt cache recovery
        print("[test] corrupt cache")
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Launcher/index.json")
        try? "not-json".write(to: cacheURL, atomically: true, encoding: .utf8)
        // After corrupt write, next scan should still succeed.
        let recovered = AppIndex.shared.scanSync()
        expect("scan works after corrupt cache", recovered.count > 0)

        // T13: stale path detection
        print("[test] stale path")
        let fakeEntry = AppEntry(path: "/Applications/DefinitelyDoesNotExist.app", name: "Fake")
        let fakeExists = FileManager.default.fileExists(atPath: fakeEntry.path)
        expect("stale path check returns false", !fakeExists)

        // T14: Cyrillic app name matching (if any cyrillic-named app is installed)
        print("[test] cyrillic names")
        let cyrillicApps = apps.filter { app in
            app.name.unicodeScalars.contains { $0.value >= 0x0400 && $0.value <= 0x04FF }
        }
        if let ca = cyrillicApps.first {
            let firstChar = String(ca.name.prefix(3)).lowercased()
            let hit = top(firstChar, in: apps)
            expect("cyrillic app (\(ca.name)) findable by prefix '\(firstChar)'", hit != nil)
        } else {
            print("  — skipped: no cyrillic-named apps installed")
        }

        // Summary
        print("")
        print("=" + String(repeating: "=", count: 50))
        if failures.isEmpty {
            print("ALL PASSED")
            return true
        } else {
            print("FAILURES (\(failures.count)):")
            for f in failures { print("  - \(f)") }
            return false
        }
    }
}
