import Foundation

/// Bidirectional QWERTY ↔ ЙЦУКЕН key-position swap.
/// Used to catch "user typed on wrong layout" case.
enum KeyboardLayout {
    private static let enToRu: [Character: Character] = [
        "q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з",
        "a":"ф","s":"ы","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",
        "z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь",
        "`":"ё","[":"х","]":"ъ",";":"ж","'":"э",",":"б",".":"ю",
    ]

    private static let ruToEn: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (k, v) in enToRu { m[v] = k }
        return m
    }()

    static func enToRuSwap(_ s: String) -> String {
        String(s.lowercased().map { enToRu[$0] ?? $0 })
    }

    static func ruToEnSwap(_ s: String) -> String {
        String(s.lowercased().map { ruToEn[$0] ?? $0 })
    }

    /// All candidate queries: original + both swaps (deduplicated).
    static func variants(_ q: String) -> [String] {
        let lo = q.lowercased()
        var out: [String] = [lo]
        let en = ruToEnSwap(lo)
        let ru = enToRuSwap(lo)
        if en != lo { out.append(en) }
        if ru != lo { out.append(ru) }
        return out
    }
}
