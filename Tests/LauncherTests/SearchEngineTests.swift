import XCTest
@testable import Launcher

final class SearchEngineTests: XCTestCase {
    private func names(_ query: String, apps: [AppEntry], recents: [String] = []) -> [String] {
        SearchEngine.search(query: query, in: SearchIndex(apps), recents: recents).map(\.name)
    }

    func testMatchTiersKeepTheirOrder() {
        let apps = [
            AppEntry(path: "/subsequence", name: "N-o-t-i-o-n"),
            AppEntry(path: "/substring", name: "XNotion"),
            AppEntry(path: "/word", name: "My Notion"),
            AppEntry(path: "/prefix", name: "Notion Calendar"),
            AppEntry(path: "/exact", name: "Notion"),
        ]
        XCTAssertEqual(names("notion", apps: apps),
                       ["Notion", "Notion Calendar", "My Notion", "XNotion", "N-o-t-i-o-n"])
    }

    func testTiesSortByDisplayNameRegardlessOfIndexOrder() {
        let apps = [
            AppEntry(path: "/z", name: "Zulu", aliases: ["editor"]),
            AppEntry(path: "/a", name: "Alpha", aliases: ["editor"]),
            AppEntry(path: "/b", name: "Beta", aliases: ["editor"]),
        ]
        XCTAssertEqual(names("editor", apps: apps), ["Alpha", "Beta", "Zulu"])
        XCTAssertEqual(names("editor", apps: apps, recents: ["/z"]), ["Zulu", "Alpha", "Beta"])
    }

    func testEqualDisplayNamesKeepIndexOrder() {
        let apps = [
            AppEntry(path: "/second", name: "Editor"),
            AppEntry(path: "/first", name: "EDITOR"),
        ]
        let paths = SearchEngine.search(query: "editor", in: SearchIndex(apps), recents: []).map(\.path)
        XCTAssertEqual(paths, ["/second", "/first"])
    }

    func testEmptyQueryPreservesRecentsAndRemainingIndexOrder() {
        let apps = [
            AppEntry(path: "/a", name: "Alpha"),
            AppEntry(path: "/b", name: "Beta"),
            AppEntry(path: "/c", name: "Charlie"),
        ]
        XCTAssertEqual(names(" \n ", apps: apps, recents: ["/c", "/gone", "/a"]),
                       ["Charlie", "Alpha", "Beta"])
    }

    func testLayoutSwapAndUnicodeNamesRemainSearchable() {
        let apps = [
            AppEntry(path: "/notion", name: "Notion"),
            AppEntry(path: "/calendar", name: "Календарь"),
            AppEntry(path: "/tokyo", name: "東京"),
            AppEntry(path: "/cafe", name: "Café"),
        ]
        XCTAssertEqual(names("тщешщт", apps: apps), ["Notion"])
        XCTAssertEqual(names("rfkty", apps: apps), ["Календарь"])
        XCTAssertEqual(names("кале", apps: apps), ["Календарь"])
        XCTAssertEqual(names("東", apps: apps), ["東京"])
        XCTAssertEqual(names("CAFÉ", apps: apps), ["Café"])
    }

    func testMaskCollisionsAndRepeatedBytesStillRequireARealMatch() {
        let apps = [
            AppEntry(path: "/one", name: "A"),
            AppEntry(path: "/two", name: "Aa"),
            AppEntry(path: "/collision", name: "!"),
        ]
        XCTAssertEqual(names("aa", apps: apps), ["Aa"])
        XCTAssertEqual(names("a", apps: apps), ["A", "Aa"])
        XCTAssertEqual(names("xyz", apps: apps), [])
    }

    func testAliasesAndCaseAreSearchable() {
        let apps = [AppEntry(path: "/code", name: "Code", aliases: ["Code", "Visual Studio Code"])]
        XCTAssertEqual(names("  VISUAL STUDIO  ", apps: apps), ["Code"])
        XCTAssertEqual(names("studio", apps: apps), ["Code"])
        XCTAssertEqual(names("vsc", apps: apps), ["Code"])
    }
}
