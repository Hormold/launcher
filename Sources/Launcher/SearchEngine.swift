import Foundation

enum SearchEngine {
    /// Search the prepared index without rebuilding aliases or comparing display names.
    static func search(query: String, in index: SearchIndex, recents: [String]) -> [AppEntry] {
        let idx = index.entries
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            let recentOffsets = recents.compactMap { index.offsetsByPath[$0] }
            let recentSet = Set(recentOffsets)
            let recentApps = recentOffsets.map { idx[$0].app }
            let rest = idx.enumerated().compactMap { recentSet.contains($0.offset) ? nil : $0.element.app }
            return recentApps + rest
        }

        // Pre-compute byte arrays for each query variant.
        let variants = KeyboardLayout.variants(q).map { variant in
            let bytes = Array(variant.utf8)
            return (bytes: bytes, mask: IndexedApp.byteMask(bytes))
        }

        // Resolve recent paths once per query, then score using integer offsets.
        var recentBoost = [Int](repeating: 0, count: recents.isEmpty ? 0 : idx.count)
        for (i, path) in recents.enumerated() {
            if let offset = index.offsetsByPath[path] { recentBoost[offset] = max(0, 20 - i * 2) }
        }

        var scored: [(offset: Int, score: Int)] = []
        scored.reserveCapacity(idx.count)

        for (offset, ix) in idx.enumerated() {
            var best: Int = -1
            // Iterate aliases × variants. Aliases are typically 1-3, variants 1-3.
            for ai in 0..<ix.aliasBytes.count {
                let n = ix.aliasBytes[ai]
                let words = ix.aliasWords[ai]
                for variant in variants {
                    // Colliding bits can admit a non-match, but never reject a match.
                    if ix.aliasMasks[ai] & variant.mask != variant.mask { continue }
                    if let s = scoreBytes(q: variant.bytes, n: n, words: words), s > best {
                        best = s
                        if best >= 1000 { break } // exact match — can't beat
                    }
                }
                if best >= 1000 { break }
            }
            if best < 0 { continue }
            let boost = recentBoost.isEmpty ? 0 : recentBoost[offset]
            scored.append((offset, best + boost))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return index.alphabeticalRanks[lhs.offset] < index.alphabeticalRanks[rhs.offset]
        }
        return scored.map { idx[$0.offset].app }
    }

    /// Byte-level scorer. Returns nil if no match. Higher score = better.
    /// Tier order: exact (1000) > prefix (500) > word-prefix (300) > substring (200) > subseq (50+).
    @inline(__always)
    static func scoreBytes(q: [UInt8], n: [UInt8], words: [[UInt8]]) -> Int? {
        let qc = q.count
        let nc = n.count
        if qc == 0 { return 0 }
        if qc > nc { return nil }

        return q.withUnsafeBufferPointer { qp in
            n.withUnsafeBufferPointer { np in
                guard let query = qp.baseAddress, let name = np.baseAddress else { return nil }
                let lengthBonus = max(0, 50 - nc)
                if memcmp(name, query, qc) == 0 {
                    return qc == nc ? 1000 : 500 + lengthBonus
                }
                for word in words where word.count >= qc {
                    let matches = word.withUnsafeBufferPointer { wp in
                        memcmp(wp.baseAddress, query, qc) == 0
                    }
                    if matches { return 300 + lengthBonus }
                }

                // Check substring and subsequence together in one pass through the name.
                var qi = 0
                var runs = 0
                var inRun = false
                for ni in 0..<nc {
                    if name[ni] == query[0], ni <= nc - qc,
                       memcmp(name + ni, query, qc) == 0 {
                        return 200 + lengthBonus
                    }
                    if qi < qc {
                        if name[ni] == query[qi] {
                            if !inRun { runs += 1 }
                            inRun = true
                            qi += 1
                        } else {
                            inRun = false
                        }
                    }
                }
                return qi == qc ? 50 + max(0, 10 - runs) - nc / 4 : nil
            }
        }
    }

    // One-shot entry point for diagnostics. Interactive searches reuse SearchIndex.
    static func search(query: String, in apps: [AppEntry], recents: [String]) -> [AppEntry] {
        search(query: query, in: SearchIndex(apps), recents: recents)
    }
}
