import AppKit

@main struct DesktopInputTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func parse(_ s: String) -> KeyChord? { if case .success(let c) = KeyChord.parse(s) { return c } else { return nil } }

        // Shortcuts: anything not understood presses nothing.
        for bad in ["nonsense+return", "return+nonsense", "return+tab", "shift", "cmd+", "+v", "cmd++v", "cmd+cmd+v", "", "  ", "cmd+shift", "a+b"] {
            check(parse(bad) == nil, "malformed shortcut refused: \(bad.debugDescription)")
        }
        check(parse("cmd+return")?.key == .named(0x24), "cmd+return accepted")
        check(parse("Cmd + Shift + T") == KeyChord(modifiers: [.command, .shift], key: .character("t")), "case and spaces tolerated")
        check(parse("page_down")?.key == .named(0x79) && parse("Page-Up")?.key == .named(0x74), "page key spellings")
        check(parse("cmd+minus")?.key == .character("-") && parse("cmd+plus")?.key == .character("="), "spelled punctuation")
        check(parse("ctrl+opt+fn+left")?.modifiers == [.control, .option, .function], "all modifiers")

        // Click options.
        func clicks(_ d: [String: Any]) -> ClickOptions? { if case .success(let o) = ClickOptions.parse(d) { return o } else { return nil } }
        check(clicks(["do": "click", "x": 1, "y": 2])?.isPlain == true, "no options is a plain click")
        let rich = clicks(["button": "right", "count": 2, "modifiers": ["cmd", "shift"], "duration_ms": 120])
        check(rich?.button == .right && rich?.count == 2 && rich?.modifiers == [.command, .shift] && rich?.holdMilliseconds == 120, "options honoured")
        check(rich?.isPlain == false, "options require pixel input, not AXPress")
        check(clicks(["modifiers": "cmd+opt"])?.modifiers == [.command, .option], "plus-joined modifiers")
        check(rich?.steps == [.init(down: true, clickState: 1), .init(down: false, clickState: 1), .init(down: true, clickState: 2), .init(down: false, clickState: 2)],
              "double click carries rising click states")
        for bad in [["button": "side"], ["button": 3], ["count": 0], ["count": 4], ["count": 1.5], ["count": true], ["modifiers": ["hyper"]],
                    ["modifiers": ["cmd", "command"]], ["modifiers": ["fn"]], ["modifiers": 5], ["duration_ms": -1], ["duration_ms": 6000],
                    ["duration_ms": Double.nan], ["duration_ms": "long"]] as [[String: Any]] {
            check(clicks(bad) == nil, "invalid click option refused: \(bad)")
        }

        // Scroll.
        func plan(_ d: [String: Any]) -> ScrollPlan? { if case .success(let p) = ScrollPlan.parse(d) { return p } else { return nil } }
        let view = CGSize(width: 1000, height: 800)
        check(plan([:])?.direction == .down && plan([:])?.isDefault == true, "legacy default scroll is down")
        check(plan(["dir": "sideways"]) == nil && plan(["dir": 3]) == nil, "unknown direction refused instead of scrolling down")
        check(plan(["dir": "left"])?.direction == .left && plan(["direction": "RIGHT"])?.direction == .right, "horizontal directions")
        check(plan(["dir": "up", "amount": 0]) == nil && plan(["dir": "up", "amount": -2]) == nil && plan(["amount": 999]) == nil, "bad amounts refused")
        check(plan(["unit": "furlongs", "amount": 1]) == nil && plan(["unit": "pixels"]) == nil, "bad or unfinished unit refused")
        check(plan(["amount": 5000, "unit": "lines"]) == nil && plan(["amount": 25_000, "unit": "pixels"]) == nil, "unit-specific bounds")
        let down7 = plan(["dir": "down", "amount": 7])!.chunks(viewport: view)
        check(!down7.usesPixels && down7.steps.map { Int($0.dy) }.reduce(0, +) == -7 && down7.steps.allSatisfy { $0.dx == 0 }, "7 lines down is exactly 7 lines")
        let left = plan(["dir": "left", "amount": 300, "unit": "pixels"])!.chunks(viewport: view)
        check(left.usesPixels && left.steps.map { Int($0.dx) }.reduce(0, +) == 300 && left.steps.allSatisfy { $0.dy == 0 }, "300 px left on the horizontal axis")
        check(plan(["dir": "right", "amount": 1, "unit": "lines"])!.chunks(viewport: view).steps.first?.dx == -1, "right is negative horizontal")
        let pages = plan(["dir": "up", "amount": 2, "unit": "pages"])!.chunks(viewport: view)
        check(pages.usesPixels && pages.steps.map { Int($0.dy) }.reduce(0, +) == Int((2 * 800 * 0.9).rounded()), "two pages are two viewports of pixels")
        check(plan([:])!.chunks(viewport: view).steps.map { Int($0.dy) }.reduce(0, +) == -12, "default keeps its 12 lines")

        // Desired control state.
        func desire(_ role: String, _ raw: Any?) -> DesiredState? { if case .success(let d) = DesiredState.parse(role: role, raw: raw) { return d } else { return nil } }
        check(desire("AXCheckBox", true) == .on && desire("AXCheckBox", "off") == .off && desire("AXSwitch", "checked") == .on, "checkbox states")
        check(desire("AXCheckBox", "maybe") == nil && desire("AXCheckBox", 7) == nil && desire("AXCheckBox", nil) == nil, "unclear checkbox state refused")
        check(desire("AXRadioButton", true) == .on && desire("AXRadioButton", false) == nil, "a radio cannot be switched off")
        check(desire("AXSlider", 0.5) == .value(0.5) && desire("AXSlider", Double.infinity) == nil && desire("AXSlider", "half") == nil, "range values finite numbers")
        check(desire("AXButton", true) == nil, "other roles refused")
        check(DesiredState.on.matches(NSNumber(value: 1)) && !DesiredState.on.matches(NSNumber(value: 2)) && !DesiredState.on.matches(nil), "mixed or unknown never matches")
        check(DesiredState.off.matches(NSNumber(value: 0)) && DesiredState.value(0.5).matches(NSNumber(value: 0.504), tolerance: 0.01), "tolerance for ranges")

        // Text placement.
        let hello = "hello world"
        check(TextEditMode.insertAtCaret.apply(to: hello, selection: NSRange(location: 5, length: 0), text: ",")?.value == "hello, world", "insert at caret")
        check(TextEditMode.insertAtCaret.apply(to: hello, selection: NSRange(location: 6, length: 5), text: "there")?.value == "hello there", "typing over a selection replaces it")
        check(TextEditMode.insertAtCaret.apply(to: hello, selection: NSRange(location: 5, length: 0), text: ",")?.caret == 6, "caret moves past inserted text")
        check(TextEditMode.insertAtCaret.apply(to: hello, selection: nil, text: "x") == nil, "no caret means unsupported, not a guess")
        check(TextEditMode.insertAtCaret.apply(to: hello, selection: NSRange(location: 9, length: 9), text: "x") == nil, "selection beyond the text refused")
        check(TextEditMode.append.apply(to: hello, selection: nil, text: "!")?.value == "hello world!", "append")
        check(TextEditMode.replaceAll.apply(to: hello, selection: nil, text: "new")?.value == "new", "replace")
        check(TextEditMode.insertAtCaret.apply(to: "a😀b", selection: NSRange(location: 3, length: 0), text: "-")?.value == "a😀-b", "UTF-16 offsets")

        // Choosing by title.
        let fold: (String) -> String = { $0.lowercased() }
        check(TitleChoice.choose(titles: ["Notes", "Notes"], wanted: "notes", normalize: fold) == .ambiguous([0, 1]), "repeated titles are ambiguous")
        check(TitleChoice.choose(titles: ["Report", "Report draft"], wanted: "report", normalize: fold) == .one(0), "exact beats partial")
        check(TitleChoice.choose(titles: ["Report v1", "Report v2"], wanted: "report", normalize: fold) == .ambiguous([0, 1]), "two prefixes are ambiguous")
        check(TitleChoice.choose(titles: ["Inbox", "Draft report"], wanted: "report", normalize: fold) == .one(1), "unique substring accepted")
        check(TitleChoice.choose(titles: ["Inbox"], wanted: "zzz", normalize: fold) == .none && TitleChoice.choose(titles: ["x"], wanted: "", normalize: fold) == .none, "no match")

        // Clipboard: every format returns, but never over the user's newer copy.
        let board = NSPasteboard(name: NSPasteboard.Name("clinqy-desktop-input-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let rtf = Data("{\\rtf1 styled}".utf8), png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string); item.setData(rtf, forType: .rtf); item.setData(png, forType: .png)
        board.writeObjects([item, { let i = NSPasteboardItem(); i.setString("second", forType: .string); return i }()])
        let snapshot = PasteboardSnapshot(board)
        board.clearContents(); board.setString("temporary", forType: .string)
        let ours = board.changeCount
        check(snapshot.restore(to: board, ifUnchangedSince: ours), "restore happens while the clipboard is still ours")
        check(board.pasteboardItems?.count == 2, "both items restored")
        check(board.pasteboardItems?.first?.data(forType: .rtf) == rtf && board.pasteboardItems?.first?.data(forType: .png) == png, "rich formats preserved")
        board.clearContents(); board.setString("temporary", forType: .string)
        let stale = board.changeCount
        board.clearContents(); board.setString("the user's newer copy", forType: .string)
        check(!snapshot.restore(to: board, ifUnchangedSince: stale) && board.string(forType: .string) == "the user's newer copy", "a copy made meanwhile is left alone")
        let empty = PasteboardSnapshot(NSPasteboard(name: NSPasteboard.Name("clinqy-desktop-input-empty-\(UUID().uuidString)")))
        board.clearContents(); board.setString("temporary", forType: .string)
        check(empty.isEmpty && empty.restore(to: board, ifUnchangedSince: board.changeCount) && board.string(forType: .string) == nil, "an empty clipboard is restored empty")

        print("PASS: \(checks) desktop input checks")
    }
}
