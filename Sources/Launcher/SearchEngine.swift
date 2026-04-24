import Foundation

enum SearchEngine {
    /// Public entry. Operates on `IndexedApp` (pre-computed UTF-8 bytes).
    static func search(query: String, in idx: [IndexedApp], recents: [String]) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            let recentSet = Set(recents)
            let recentApps = recents.compactMap { p in idx.first { $0.app.path == p }?.app }
            let rest = idx.compactMap { recentSet.contains($0.app.path) ? nil : $0.app }
            return recentApps + rest
        }

        // Pre-compute byte arrays for each query variant.
        let variantBytes: [[UInt8]] = KeyboardLayout.variants(q).map { Array($0.utf8) }

        // Recents → small bonus. Build once.
        var recentBoost: [String: Int] = [:]
        for (i, p) in recents.enumerated() { recentBoost[p] = max(0, 20 - i * 2) }

        var scored: [(AppEntry, Int)] = []
        scored.reserveCapacity(idx.count)

        for ix in idx {
            var best: Int = -1
            // Iterate aliases × variants. Aliases are typically 1-3, variants 1-3.
            for ai in 0..<ix.aliasBytes.count {
                let n = ix.aliasBytes[ai]
                let words = ix.aliasWords[ai]
                for v in variantBytes {
                    if v.isEmpty { continue }
                    if let s = scoreBytes(q: v, n: n, words: words), s > best {
                        best = s
                        if best >= 1000 { break } // exact match — can't beat
                    }
                }
                if best >= 1000 { break }
            }
            if best < 0 { continue }
            let boost = recentBoost[ix.app.path] ?? 0
            scored.append((ix.app, best + boost))
        }

        scored.sort { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        return scored.map { $0.0 }
    }

    /// Byte-level scorer. Returns nil if no match. Higher score = better.
    /// Tier order: exact (1000) > prefix (500) > word-prefix (300) > substring (200) > subseq (50+).
    @inline(__always)
    static func scoreBytes(q: [UInt8], n: [UInt8], words: [[UInt8]]) -> Int? {
        let qc = q.count
        let nc = n.count
        if qc == 0 { return 0 }
        if qc > nc { return nil }

        // Cheap rejection: if first byte of query never appears in name, no match possible.
        // Saves the expensive subsequence/substring loops for ~80% of non-matching apps.
        let q0 = q[0]
        var hasQ0 = false
        n.withUnsafeBufferPointer { np in
            for i in 0..<nc where np[i] == q0 { hasQ0 = true; break }
        }
        if !hasQ0 { return nil }

        // Exact
        if qc == nc && bytesEqual(q, n) { return 1000 }

        // Prefix
        if hasPrefix(n, q) { return 500 + max(0, 50 - nc) }

        // Word-prefix
        for w in words {
            if hasPrefix(w, q) { return 300 + max(0, 50 - nc) }
        }

        // Substring
        if containsBytes(haystack: n, needle: q) { return 200 + max(0, 50 - nc) }

        // Subsequence (all bytes of q appear in n in order)
        if let runs = subseqRuns(q: q, n: n) {
            return 50 + runs - nc / 4
        }
        return nil
    }

    @inline(__always)
    private static func bytesEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        return a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                memcmp(ap.baseAddress, bp.baseAddress, a.count) == 0
            }
        }
    }

    @inline(__always)
    private static func hasPrefix(_ n: [UInt8], _ q: [UInt8]) -> Bool {
        if q.count > n.count { return false }
        return n.withUnsafeBufferPointer { np in
            q.withUnsafeBufferPointer { qp in
                memcmp(np.baseAddress, qp.baseAddress, q.count) == 0
            }
        }
    }

    @inline(__always)
    private static func containsBytes(haystack: [UInt8], needle: [UInt8]) -> Bool {
        let nc = needle.count
        let hc = haystack.count
        if nc == 0 { return true }
        if nc > hc { return false }
        return haystack.withUnsafeBufferPointer { hp in
            needle.withUnsafeBufferPointer { np in
                guard let hbase = hp.baseAddress, let nbase = np.baseAddress else { return false }
                let limit = hc - nc
                let first = nbase.pointee
                var i = 0
                while i <= limit {
                    if hbase[i] == first {
                        if memcmp(hbase + i, nbase, nc) == 0 { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }

    /// Returns "10 - run count" (so higher is better, more contiguous), or nil.
    @inline(__always)
    private static func subseqRuns(q: [UInt8], n: [UInt8]) -> Int? {
        let qc = q.count
        let nc = n.count
        var qi = 0
        var ni = 0
        var runs = 0
        var inRun = false
        q.withUnsafeBufferPointer { qp in
            n.withUnsafeBufferPointer { np in
                while qi < qc && ni < nc {
                    if qp[qi] == np[ni] {
                        if !inRun { runs += 1; inRun = true }
                        qi += 1
                    } else {
                        inRun = false
                    }
                    ni += 1
                }
            }
        }
        if qi < qc { return nil }
        return max(0, 10 - runs)
    }

    // Legacy wrapper for `--probe` and self-test that still pass `[AppEntry]`.
    static func search(query: String, in apps: [AppEntry], recents: [String]) -> [AppEntry] {
        search(query: query, in: apps.map(IndexedApp.init), recents: recents)
    }
}
