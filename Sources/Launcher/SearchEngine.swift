import Foundation

struct ScoredApp {
    let app: AppEntry
    let score: Int
    let matchRanges: [Range<String.Index>]
}

enum SearchEngine {
    static func search(query: String, in apps: [AppEntry], recents: [String]) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            // Recents first, then alphabetic remainder.
            let recentSet = Set(recents)
            let recentApps = recents.compactMap { path in apps.first(where: { $0.path == path }) }
            let rest = apps.filter { !recentSet.contains($0.path) }
            return recentApps + rest
        }

        var scored: [(AppEntry, Int)] = []
        scored.reserveCapacity(apps.count)

        let recentBoostMap: [String: Int] = {
            var m: [String: Int] = [:]
            for (i, p) in recents.enumerated() {
                m[p] = max(0, 20 - i * 2)
            }
            return m
        }()

        let variants = KeyboardLayout.variants(q)

        for app in apps {
            var best: Int = -1
            // Score against every alias (file name + CFBundleDisplayName + CFBundleName),
            // take the max. Handles e.g. "Code.app" ↔ "Visual Studio Code" display name.
            for alias in app.aliases {
                for v in variants {
                    if let s = score(query: v, name: alias), s > best { best = s }
                }
            }
            if best < 0 { continue }
            let boost = recentBoostMap[app.path] ?? 0
            scored.append((app, best + boost))
        }
        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        return scored.map { $0.0 }
    }

    /// Returns nil if query does not match. Higher score = better.
    static func score(query q: String, name n: String) -> Int? {
        if q.isEmpty { return 0 }
        if n == q { return 1000 }
        if n.hasPrefix(q) { return 500 + max(0, 50 - n.count) }

        // Word-prefix: any whitespace/punct-delimited word starts with q
        let words = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for w in words {
            if w.hasPrefix(q) { return 300 + max(0, 50 - n.count) }
        }

        // Substring contains
        if n.contains(q) { return 200 + max(0, 50 - n.count) }

        // Subsequence (fuzzy). Reward contiguous runs.
        guard let runs = subsequenceRuns(q: q, n: n) else { return nil }
        return 50 + runs - n.count / 4
    }

    /// If q is a subsequence of n, return number of contiguous runs (higher = better).
    /// Nil if not a subsequence.
    private static func subsequenceRuns(q: String, n: String) -> Int? {
        var qi = q.startIndex
        var ni = n.startIndex
        var runs = 0
        var inRun = false
        while qi < q.endIndex && ni < n.endIndex {
            if q[qi] == n[ni] {
                if !inRun { runs += 1; inRun = true }
                qi = q.index(after: qi)
            } else {
                inRun = false
            }
            ni = n.index(after: ni)
        }
        if qi < q.endIndex { return nil }
        // Fewer runs = better (more contiguous). Invert so higher=better.
        return max(0, 10 - runs)
    }
}
