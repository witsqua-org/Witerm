import XCTest
@testable import WitermMac

/// Round 26: Open Quickly's ranking, snippet blanks, and the name of a
/// terminal started in the same folder.
@MainActor final class Round26Tests: XCTestCase {
    private func item(_ id: String, _ title: String, kind: QuickOpenItem.Kind = .command,
                      detail: String? = nil, keywords: [String] = []) -> QuickOpenItem {
        QuickOpenItem(id: id, kind: kind, title: title, detail: detail, symbol: "terminal", keywords: keywords) {}
    }

    // MARK: Open Quickly

    func testScoreOrdersExactPrefixInitialsWordSubstringAndLettersInOrder() throws {
        let exact = try XCTUnwrap(QuickOpenRanking.score("build", in: "Build"))
        let prefix = try XCTUnwrap(QuickOpenRanking.score("bui", in: "Build logs"))
        let initials = try XCTUnwrap(QuickOpenRanking.score("ntis", in: "New Terminal in Same Folder"))
        let word = try XCTUnwrap(QuickOpenRanking.score("logs", in: "Build logs"))
        let middle = try XCTUnwrap(QuickOpenRanking.score("uil", in: "Build logs"))
        let letters = try XCTUnwrap(QuickOpenRanking.score("bdl", in: "Build logs"))
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, initials)
        XCTAssertGreaterThan(initials, word)
        XCTAssertGreaterThan(word, middle)
        XCTAssertGreaterThan(middle, letters)
        XCTAssertNil(QuickOpenRanking.score("xyz", in: "New Terminal"))
        XCTAssertNil(QuickOpenRanking.score("tn", in: "nt"), "Letters must come in order")
        // Initials beat the same letters mid-word, and letters that start
        // words beat letters that don't.
        XCTAssertGreaterThan(try XCTUnwrap(QuickOpenRanking.score("nt", in: "New Terminal")),
                             try XCTUnwrap(QuickOpenRanking.score("nt", in: "Content")))
        XCTAssertGreaterThan(try XCTUnwrap(QuickOpenRanking.score("ntf", in: "New Terminal Folder")),
                             try XCTUnwrap(QuickOpenRanking.score("ntf", in: "inotify")))
        XCTAssertGreaterThan(try XCTUnwrap(QuickOpenRanking.score("nwtl", in: "New Terminal")),
                             try XCTUnwrap(QuickOpenRanking.score("nwtl", in: "nowtotal")))
    }

    func testScoreIgnoresCaseAccentsAndWidth() {
        XCTAssertEqual(QuickOpenRanking.score("cafe", in: "Café"), 1_000)
        XCTAssertEqual(QuickOpenRanking.score("UBUNTU", in: "ubuntu"), 1_000)
        XCTAssertEqual(QuickOpenRanking.score("ｗｅｂ", in: "web"), 1_000)
        XCTAssertNotNil(QuickOpenRanking.score("终端", in: "终端 2"))
    }

    func testTitleBeatsKeywordAndDetail() {
        let items = [item("a", "Settings…", keywords: ["ssh"]),
                     item("b", "prod", kind: .host, detail: "deploy@ssh.example.com"),
                     item("c", "ssh-bastion", kind: .host)]
        XCTAssertEqual(QuickOpenRanking.rank(items, query: "ssh", recent: []).map(\.id), ["c", "a", "b"])
    }

    func testRecentChoicesComeFirstAndRankHigher() {
        let items = [item("local:1", "Terminal 1", kind: .terminal), item("local:2", "Terminal 2", kind: .terminal),
                     item("action:new", "New Terminal"), item("snippet:x", "Tail logs", kind: .snippet)]
        // Nothing typed: recent in order, then by kind; snippets only once used.
        XCTAssertEqual(QuickOpenRanking.rank(items, query: "", recent: ["local:2"]).map(\.id),
                       ["local:2", "local:1", "action:new"])
        XCTAssertEqual(QuickOpenRanking.rank(items, query: " ", recent: ["snippet:x"]).first?.id, "snippet:x")
        // Typed: a recent equal match wins the tie.
        XCTAssertEqual(QuickOpenRanking.rank(items, query: "terminal", recent: ["local:2"]).first?.id, "local:2")
        XCTAssertEqual(QuickOpenRanking.rank(items, query: "terminal", recent: []).first?.id, "local:1")
        XCTAssertEqual(QuickOpenRanking.rank(items, query: "tail", recent: []).map(\.id), ["snippet:x"])
    }

    func testRememberMovesToFrontAndCaps() {
        var recent: [String] = []
        for index in 0..<25 { recent = QuickOpenRanking.remember("id\(index)", in: recent) }
        XCTAssertEqual(recent.count, QuickOpenRanking.recentLimit)
        XCTAssertEqual(recent.first, "id24")
        recent = QuickOpenRanking.remember("id10", in: recent)
        XCTAssertEqual(recent.first, "id10")
        XCTAssertEqual(recent.filter { $0 == "id10" }.count, 1)
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: "witerm.round26.\(UUID().uuidString)"))
        QuickOpenRanking.saveRecent(recent, to: defaults)
        XCTAssertEqual(QuickOpenRanking.loadRecent(from: defaults), recent)
    }

    // MARK: Snippet blanks

    func testBlanksAreNamedOnceInOrderAndTemplatesAreLeftAlone() {
        XCTAssertEqual(SnippetPlaceholders.names(in: "ssh {{user}}@{{ host }} -p {{port}} # {{user}}"), ["user", "host", "port"])
        XCTAssertEqual(SnippetPlaceholders.names(in: "docker inspect -f '{{.State.Status}}' {{container name}}"), ["container name"])
        XCTAssertEqual(SnippetPlaceholders.names(in: "{{json .}} {{}} {{1st}} {{a}b}} {{ok_2}}"), ["ok_2"])
        XCTAssertEqual(SnippetPlaceholders.names(in: "git switch {{分支}}"), ["分支"])
        XCTAssertEqual(SnippetPlaceholders.names(in: "echo {{unclosed"), [])
        XCTAssertEqual(SnippetPlaceholders.names(in: "{{{name}}}"), ["name"])
    }

    func testFillReplacesEveryUseAndKeepsTheRest() {
        let text = "ssh {{user}}@{{host}} -p {{port}}; echo {{user}} '{{.Name}}'"
        XCTAssertEqual(SnippetPlaceholders.fill(text, values: ["user": "deploy", "host": "example.com", "port": "2222"]),
                       "ssh deploy@example.com -p 2222; echo deploy '{{.Name}}'")
        XCTAssertEqual(SnippetPlaceholders.fill(text, values: ["user": "a"]),
                       "ssh a@{{host}} -p {{port}}; echo a '{{.Name}}'")
        // Values are typed as given, never as new blanks or quoted.
        XCTAssertEqual(SnippetPlaceholders.fill("cd {{dir}}", values: ["dir": "{{dir}} $HOME"]), "cd {{dir}} $HOME")
    }

    func testValuesCantCarryControlCharacters() {
        XCTAssertTrue(SnippetPlaceholders.validValue("main"))
        XCTAssertTrue(SnippetPlaceholders.validValue(""))
        XCTAssertFalse(SnippetPlaceholders.validValue("main\nrm -rf ~"))
        XCTAssertFalse(SnippetPlaceholders.validValue("a\u{1b}[2J"))
        XCTAssertFalse(SnippetPlaceholders.validValue(String(repeating: "x", count: 1_025)))
    }

    func testFilledSnippetTypesItsValuesAndKeepsReturn() {
        let snippet = CommandSnippet(name: "Switch", text: "git switch {{branch}}", runsImmediately: true)
        let filled = snippet.filled(["branch": "main"])
        XCTAssertEqual(filled.id, snippet.id)
        XCTAssertEqual(String(decoding: filled.input(bracketedPaste: false), as: UTF8.self), "git switch main\r")
        XCTAssertEqual(snippet.placeholders, ["branch"])
        XCTAssertTrue(filled.placeholders.isEmpty)
    }

    func testRecentValuesStayInMemoryPerSnippet() {
        let first = CommandSnippet(name: "One", text: "{{a}}"), second = CommandSnippet(name: "Two", text: "{{a}}")
        SnippetRecentValues.remember(["a": "x"], for: first)
        XCTAssertEqual(SnippetRecentValues.values(for: first), ["a": "x"])
        XCTAssertEqual(SnippetRecentValues.values(for: second), [:])
    }

    // MARK: New Terminal in Same Folder

    func testFolderNamesTheNewTerminal() {
        let home = "/Users/someone"
        XCTAssertEqual(LocalTerminalModel.name(forFolder: "/Users/someone/src/Witerm", home: home, taken: []), "Witerm")
        XCTAssertEqual(LocalTerminalModel.name(forFolder: "/Users/someone/src/Witerm/", home: home, taken: []), "Witerm")
        XCTAssertEqual(LocalTerminalModel.name(forFolder: "/srv/app", home: home, taken: ["app", "app 2"]), "app 3")
        XCTAssertNil(LocalTerminalModel.name(forFolder: home, home: home, taken: []), "Home says nothing; use Terminal N")
        XCTAssertNil(LocalTerminalModel.name(forFolder: "/", home: home, taken: []))
        let long = "/tmp/" + String(repeating: "长", count: 80)
        let name = LocalTerminalModel.name(forFolder: long, home: home, taken: [])
        XCTAssertEqual(name?.count, 56, "Room is left for a number within the 64-character limit")
    }
}
