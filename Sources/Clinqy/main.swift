@preconcurrency import AVFoundation
import AppKit
import SwiftUI

// Clinqy was called CursorBoy: carry its memory, history, skills, workflows, models and settings over once.
do {
    let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    for (old, new) in [(support.appendingPathComponent("CursorBoy"), support.appendingPathComponent("Clinqy")),
                       (home.appendingPathComponent(".config/cursorboy"), home.appendingPathComponent(".config/clinqy")),
                       (home.appendingPathComponent("Library/Logs/CursorBoy"), home.appendingPathComponent("Library/Logs/Clinqy"))]
    where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: new)
    }
}
// Memory from an older build (or edited by hand) is brought to the current format once, before anything reads it.
if let report = Memory.upgradeIfNeeded() { print("🧠 \(report)") }

// Terminal run: `Clinqy --run <bundle-id|-> "<task>"` executes the task and prints a timed log.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--run" {
    let args = CommandLine.arguments
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let buddy = Buddy()
        let agent = Agent(buddy: buddy)
        agent.echo = true
        BrowserBridge.shared.start()
        if args[2] != "-" {
            agent.targetApp = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == args[2] }
        }
        agent.onFinish = { _, ok in
            // Stay alive while a mark is on screen so it can be seen.
            let marking = agent.steps.contains { $0.text.hasPrefix("Show ") }
            DispatchQueue.main.asyncAfter(deadline: .now() + (marking ? 5 : 1)) { exit(ok ? 0 : 1) }
        }
        // Give a running browser's extension a moment to connect (it retries every 20 s).
        Task { @MainActor in
            let browserOpen = NSWorkspace.shared.runningApplications.contains { Launcher.isBrowser($0) }
            for _ in 0..<50 where browserOpen && !BrowserBridge.shared.isConnected {
                try? await Task.sleep(for: .milliseconds(500))
            }
            print("extension connected: \(BrowserBridge.shared.isConnected)")
            agent.submit(args[3])
        }
        objc_setAssociatedObject(app, "agent", agent, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(app, "buddy", buddy, .OBJC_ASSOCIATION_RETAIN)
    }
    app.run()
}

// Voice check: `Clinqy --transcribe <audio file>` runs a file through the Mac's speech model, the way a spoken
// request goes (same model, language and vocabulary), and prints how long the text took after the audio ended.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--transcribe" {
    let path = CommandLine.arguments[2]
    Task { @MainActor in
        guard #available(macOS 26.0, *) else { print("needs macOS 26 (the Mac's speech model)"); exit(1) }
        let model = SpeechModel.shared
        model.prepare()
        while !model.isReady {
            if case .failed(let why) = model.state { print("failed: \(why)"); exit(1) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: audio)) != nil
        else { print("can't read audio"); exit(1) }
        guard let session = await model.start(onText: { _ in }) else { print("the speech model didn't start"); exit(1) }
        session.feed(audio)
        let started = Date()
        let text = await session.finish()
        print("\(Int(Date().timeIntervalSince(started) * 1000)) ms (\(session.model.rawValue), \(session.locale.identifier)): \(text.isEmpty ? "(nothing)" : text)")
        exit(0)
    }
    RunLoop.main.run()
}

// `--chord [key]`: taps Control+Option like a user (optionally with another key, which must NOT open Clinqy).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--chord" {
    let src = CGEventSource(stateID: .hidSystemState)
    func flags(_ code: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.type = .flagsChanged
        e?.flags = f
        e?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
    flags(0x3B, true, .maskControl)                               // control down
    flags(0x3A, true, [.maskControl, .maskAlternate])             // option down
    if CommandLine.arguments.count >= 3 { AXEngine.press(combo: "ctrl+opt+" + CommandLine.arguments[2]) }
    usleep(120_000)
    flags(0x3A, false, .maskControl)                              // option up
    flags(0x3B, false, [])                                        // control up
    usleep(300_000)
    exit(0)
}

// Test helpers that act like the user (real input events): --click-label <text>, --type <text>, --key <combo>.
if CommandLine.arguments.count >= 3, ["--click-label", "--type", "--key"].contains(CommandLine.arguments[1]) {
    let arg = CommandLine.arguments[2]
    switch CommandLine.arguments[1] {
    case "--click-label":
        guard let app = NSWorkspace.shared.frontmostApplication else { exit(1) }
        // Chromium only builds its web accessibility tree once an assistive client asks for it.
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var found: UIElementInfo?
        for _ in 0..<10 where found == nil {
            found = AXEngine.elements(of: app, limit: 600).first { $0.label.lowercased().contains(arg.lowercased()) }
            if found == nil { usleep(300_000) }
        }
        guard let el = found else { print("not found: \(arg)"); exit(1) }
        AXEngine.click(at: el.center)
        print("clicked \(el.role) \(el.label)")
    case "--type": AXEngine.type(arg)
    default: AXEngine.press(combo: arg)
    }
    usleep(300_000)
    exit(0)
}

/// Subcommands work with or without dashes (`Clinqy mcp` or `Clinqy --mcp`), like the `clinqy` command's words.
let command = CommandLine.arguments.count >= 2 && !CommandLine.arguments[1].hasPrefix("-psn")
    ? String(CommandLine.arguments[1].drop { $0 == "-" }) : ""

// `Clinqy model | connect | settings | permissions | extension install | doctor`: set Clinqy up from a terminal.
if SetupCommands.names.contains(command) { MainActor.assumeIsolated { SetupCommands.run(command, Array(CommandLine.arguments.dropFirst(2))) } }

// `Clinqy mcp`: an MCP server on stdio for other agents (`agy mcp add clinqy -- …/Clinqy mcp`).
if command == "mcp" { MCPServer.serve() }

// `clinqy control observe|act|verify|wait|release '<JSON>' [--image-out /path.jpg]`.
// The CLI and MCP share the app relay; it never starts a model for precise actions.
if command == "control" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    guard args.count >= 2, let data = args[1].data(using: .utf8),
          var body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("usage: clinqy control observe|act|verify|wait|release '<JSON>' [--image-out /path.jpg]\n", stderr); exit(2)
    }
    body["op"] = args[0]
    let imagePath = args.firstIndex(of: "--image-out").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    if args[0] == "observe" && imagePath == nil { body["image"] = false }
    Task {
        var result = await MCPServer.control(body)
        if let imagePath, var content = result["content"] as? [[String: Any]],
           let index = content.firstIndex(where: { $0["type"] as? String == "image" }),
           let encoded = content[index]["data"] as? String, let image = Data(base64Encoded: encoded) {
            do {
                let url = URL(fileURLWithPath: (imagePath as NSString).expandingTildeInPath)
                try image.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                content[index] = ["type": "text", "text": "Screenshot saved to " + url.path]
                result["content"] = content
            } catch { result["isError"] = true; result["content"] = [["type": "text", "text": "Couldn't save screenshot: " + error.localizedDescription]] }
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.withoutEscapingSlashes, .sortedKeys]) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        exit(result["isError"] as? Bool == true ? 1 : 0)
    }
    RunLoop.main.run()
    exit(1)
}

// `Clinqy stats [days] [--last]`: success rate, model vs action time per turn, top failure reasons.
if command == "stats" {
    let rest = CommandLine.arguments.dropFirst(2)
    print(Stats.report(days: rest.compactMap(Double.init).first ?? 7, last: rest.contains("--last")))
    exit(0)
}

// `Clinqy watch <app> <text> [--gone] [--timeout s]`: waits for text to appear (or go) via Accessibility notifications.
if command == "watch" {
    let rest = Array(CommandLine.arguments.dropFirst(2))
    let words = rest.enumerated().filter { !$0.element.hasPrefix("--") && ($0.offset == 0 || rest[$0.offset - 1] != "--timeout") }.map(\.element)
    guard words.count >= 2 else { print("usage: Clinqy watch <app name or bundle id> <text> [--gone] [--timeout seconds]"); exit(2) }
    let name = words[0].lowercased()
    guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier?.lowercased() == name })
            ?? NSWorkspace.shared.runningApplications.first(where: { $0.activationPolicy == .regular && ($0.localizedName ?? "").lowercased().contains(name) })
    else { print("no running app matches \(words[0])"); exit(2) }
    if !AXIsProcessTrusted() { print("note: this process has no Accessibility permission, so the app's text can't be read") }
    let timeout = rest.firstIndex(of: "--timeout").flatMap { rest.indices.contains($0 + 1) ? Double(rest[$0 + 1]) : nil } ?? 30
    let gone = rest.contains("--gone")
    Task { @MainActor in
        let t0 = Date()
        let ok = await Watch.until(app: target, text: words[1], gone: gone, timeout: timeout)
        print("\(ok ? "yes" : "timed out"): “\(words[1])” \(gone ? "gone from" : "in") \(target.localizedName ?? name) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
}

// `Clinqy replay <fixture.json|folder> [--bless]`: re-checks recorded runs offline (see Replay.swift for the format).
if command == "replay" {
    let rest = CommandLine.arguments.dropFirst(2)
    let bless = rest.contains("--bless")
    let files = rest.filter { !$0.hasPrefix("--") }.flatMap(Replay.fixtures(at:))
    guard !files.isEmpty else { print("usage: Clinqy replay <fixture.json|folder> [--bless]"); exit(2) }
    let failed = MainActor.assumeIsolated {
        var failed = 0
        for url in files {
            let r = Replay.run(url, bless: bless)
            if bless { print("blessed \(url.lastPathComponent)"); continue }
            print("\(r.failures.isEmpty ? "PASS" : "FAIL")  \(url.lastPathComponent)  (\(r.checks) checks)")
            r.failures.forEach { print("   ✗ \($0)") }
            if !r.failures.isEmpty { failed += 1 }
        }
        return failed
    }
    exit(failed == 0 ? 0 : 1)
}

// `Clinqy memory ["request"] [--app Name] [--site host] [--map]`: how memory is organised (profile, notes per site/app,
// with --map the people, places and details that link facts), and with a request, exactly which facts it would be
// sent and why (P profile, ~ brought in by a link). Read-only.
if command == "memory" {
    let args = Array(CommandLine.arguments.dropFirst(2))
    func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let query = args.enumerated().filter { i, a in !a.hasPrefix("--") && (i == 0 || !args[i - 1].hasPrefix("--")) }.map(\.1).joined(separator: " ")
    // `--fetch-model`: download the retrieval model now (the app does it by itself on its first launch).
    if args.contains("--fetch-model") {
        print("downloading \(TextEncoder.modelName) (~130 MB)…")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached { ok = await TextEncoder.fetch(); sem.signal() }
        sem.wait()
        print(ok ? "ready: \(TextEncoder.dir.path)" : "download failed (check the connection, or CLINQY_EMBEDDINGS=system is set)")
        if !ok { exit(1) }
    }
    Embedder.shared.activate(wait: true)
    Embedder.shared.warmNow(Memory.facts)
    if !Embedder.shared.usesModel, !TextEncoder.downloaded {
        print("(using the system vectors: open the Clinqy app once, or run `clinqy memory --fetch-model`, for the retrieval model)")
    }
    let entries = Memory.entries
    let profile = entries.filter { Memory.isProfile($0.text) }
    let scoped = Dictionary(grouping: entries.filter { $0.scope != nil }, by: { $0.scope!.tag })
    print("vectors: \(Embedder.shared.usesModel ? TextEncoder.modelName : "system (NaturalLanguage)")")
    print("\(entries.count) facts · \(profile.count) profile (always sent) · \(scoped.values.map(\.count).reduce(0, +)) notes for \(scoped.count) sites/apps")
    if args.contains("--map") {
        let graph = MemoryGraph(entries)
        let linked = graph.links.filter { !$0.isEmpty }.count
        print("\nmemory map: \(graph.postings.count) entities · \(linked) of \(entries.count) facts linked to another")
        let shared = graph.postings.filter { $0.value.count >= 2 }.sorted { $0.value.count > $1.value.count }
        for (entity, docs) in shared.prefix(query.isEmpty ? 40 : 0) {
            print("\n\(entity)  (\(docs.count) facts\(docs.count > max(5, entries.count / 12) ? ", too common to link" : ""))")
            docs.prefix(6).forEach { print("  - \(entries[$0].text.prefix(100))") }
        }
        let changes = Memory.history
        if !changes.isEmpty { print("\nhistory: \(changes.count) updates/removals kept in memory.history.jsonl") }
    }
    // `--eval cases.txt` (lines "request|text the right fact contains"): where recall ranks the right fact.
    if let file = option("--eval"), let text = try? String(contentsOfFile: file, encoding: .utf8) {
        var ranks: [Int] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let hits = Memory.search(parts[0])
            let r = (hits.firstIndex { $0.contains(parts[1]) } ?? 98) + 1
            ranks.append(r)
            print("  \(r == 99 ? "–" : "#\(r)")\t\(parts[0])")
        }
        let mrr = ranks.map { $0 == 99 ? 0 : 1 / Double($0) }.reduce(0, +) / Double(max(1, ranks.count))
        print("recall: #1 for \(ranks.filter { $0 == 1 }.count)/\(ranks.count) · top 3 \(ranks.filter { $0 <= 3 }.count) · top 25 \(ranks.filter { $0 <= 25 }.count) · MRR \(String(format: "%.2f", mrr))")
        exit(0)
    }
    // `--fields "Label|Label|…"`: the facts that would ride along with a page showing these fields.
    if let fields = option("--fields") {
        let t0 = Date()
        let found = Memory.forPage(labels: fields.split(separator: "|").map(String.init), excluding: [], app: option("--app"), host: option("--site"))
        print("\npage fields → \(found.count) facts (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        found.forEach { print("  - \($0.prefix(120))") }
        exit(0)
    }
    if query.isEmpty {
        if args.contains("--map") { exit(0) }
        for (tag, facts) in scoped.sorted(by: { $0.value.count > $1.value.count }) {
            print("\n\(tag)\(facts.allSatisfy(\.tagged) ? "" : " (some inferred)")")
            facts.forEach { print("  - \($0.text.prefix(110))") }
        }
    } else {
        let t0 = Date()
        let (facts, omitted, linked) = Memory.relevantExplained(to: query, app: option("--app"), host: option("--site"))
        print("\n“\(query)” → \(facts.count) facts (\(linked.count) via links), \(omitted) left out (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
        for f in facts { print("  \(Memory.isProfile(f) ? "P" : linked.contains(f) ? "~" : " ") \(args.contains("--full") ? f : String(f.prefix(120)))") }
    }
    exit(0)
}

// `Clinqy onboarding-snapshot <dir>`: renders each setup page to a PNG offscreen (for docs and checking the layout).
if command == "onboarding-snapshot" {
    let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? ".")
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Brand.registerFonts()
        let model = OnboardingModel(persistProgress: false)
        let dashboard = DashboardModel(providerChanged: {}, shortcutsChanged: {}, captureChanged: { _ in }, providerSetup: {})
        // An optional step name or "dashboard" renders just that page.
        let only = CommandLine.arguments.dropFirst(3).first
        model.showingDashboard = only == "dashboard"
        if let index = CommandLine.arguments.firstIndex(of: "--section"), index + 1 < CommandLine.arguments.count {
            dashboard.page = CommandLine.arguments[index + 1]
        }
        for step in OnboardingModel.Step.allCases where only == nil || only == "\(step)" || (only == "dashboard" && step == .welcome) {
            model.step = step
            let view = NSHostingView(rootView: OnboardingView(model: model, dashboardModel: dashboard))
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: OnboardingView.size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = model.showingDashboard ? "dashboard.png" : "onboarding-\(step.rawValue)-\(step).png"
            let url = dir.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            window.contentView = nil   // stop its animations before the next page
        }
    }
    exit(0)
}

// `Clinqy --selftest`: fast checks of logic that needs no UI (safety rules, reply parsing).
if command == "selftest" {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
    check(Safety.needsConfirmation(label: "Pay ₹500", request: "open the checkout page") != nil, "pay needs confirmation")
    check(Safety.needsConfirmation(label: "Pay ₹500", request: "pay for my order") == nil, "pay allowed when asked")
    check(Safety.needsConfirmation(label: "Submit", request: "fill the form but don't submit") != nil, "don't submit is respected")
    check(Safety.needsConfirmation(label: "Send", request: "message mom hi") == nil, "send allowed for a message request")
    check(Safety.needsConfirmation(label: "Delete", request: "open my inbox") != nil, "delete needs confirmation")
    check(Safety.needsConfirmation(label: "Search", request: "anything") == nil, "harmless click passes")
    check(Safety.needsConfirmation(label: "Book now", request: "find flights to mumbai") != nil, "booking needs confirmation")
    check(Safety.isYes("Yes, go ahead") && Safety.isYes("haan") && !Safety.isYes("No"), "yes/no parsing")
    check(MainActor.assumeIsolated { Brain.json(from: "sure {\"say\":\"x\",\"actions\":[]} ok")?["say"] as? String == "x" }, "json in prose")
    check(MainActor.assumeIsolated { (Brain.json(from: "<invoke name=\"look\">")?["actions"] as? [[String: Any]])?.first?["do"] as? String == "look" }, "tool-call tag")
    check(MainActor.assumeIsolated {
        let r = Brain.json(from: "<invoke name=\"scroll\">\n<parameter name=\"dir\">up</parameter>\n</invoke>\n<invoke name=\"scroll\">\n<parameter name=\"dir\">up</parameter>\n</invoke>\n<invoke name=\"look\">\n</invoke>")
        let a = r?["actions"] as? [[String: Any]] ?? []
        return a.count == 3 && a[0]["dir"] as? String == "up" && a[2]["do"] as? String == "look"
    }, "tool-call tags with parameters, several actions")
    check(MainActor.assumeIsolated {
        let a = (Brain.json(from: "<invoke name=\"wait\"><parameter name=\"ms\">800</parameter></invoke>")?["actions"] as? [[String: Any]])?.first
        return a?["ms"] as? Int == 800
    }, "tool-call number parameters")
    // Memory relevance: a maths question gets only core facts; food brings in the Swiggy facts.
    MainActor.assumeIsolated {
        let t0 = Date()
        Embedder.shared.activate(wait: true)
        Embedder.shared.warmNow(Memory.facts)   // the app does this in the background at launch
        let warmMs = Int(Date().timeIntervalSince(t0) * 1000)
        let t1 = Date()
        _ = Memory.relevant(to: "fill this internship application form")
        let rankMs = Int(Date().timeIntervalSince(t1) * 1000)
        print("     memory: vectors ready in \(warmMs) ms · one ranking \(rankMs) ms")
        check(rankMs < 400, "ranking memory is fast once vectors are cached")
        let all = Memory.facts.count
        let math = Memory.relevant(to: "what's 15% of 2400")
        let food = Memory.relevant(to: "order me something to eat")
        if ProcessInfo.processInfo.environment["CB_MEMDUMP"] != nil {
            for (name, r) in [("maths", math), ("food", food), ("apply", Memory.relevant(to: "fill this internship application form"))] {
                print("  [\(name)]"); r.facts.forEach { print("    - \($0.prefix(90))") }
            }
        }
        print("     memory: \(all) facts · maths sends \(math.facts.count) · food sends \(food.facts.count)")
        // Only tiny memories go along whole; growing memory is retrieved.
        let small = Memory.lines.joined().count <= Memory.sendAllBudget
        check(small ? math.omitted == 0 : all < 8 || math.facts.count < all / 2,
              small ? "small memory is sent whole" : "irrelevant facts are left out")
        check(!Memory.facts.contains { $0.contains("Swiggy") } || food.facts.contains { $0.contains("Swiggy") }, "food request brings in Swiggy facts")
    }
    // Memory scopes: tags parse, how-to lines infer their site, facts about the user stay unscoped.
    MainActor.assumeIsolated {
        let parsed = Memory.parse("""
        - [site:www.Docs.Google.com] date fields are dd/mm/yyyy; click the dd part
        - [app:Find My] open it with open_app name 'FindMy'
        - Wellfound job filters are managed at wellfound.com/jobs/filters
        - Personal email is someone@example.com
        - Likes lofi music
        """)
        check(parsed.count == 5 && parsed[0].scope == Memory.Scope(kind: "site", name: "docs.google.com") && parsed[0].tagged
              && parsed[0].text.hasPrefix("date fields") && parsed[0].line.hasPrefix("[site:docs.google.com] "), "scope tag parses and round-trips")
        check(parsed[1].scope?.matches(app: "Find My", host: nil) == true && parsed[1].scope?.matches(app: "FindMy", host: nil) == true
              && parsed[1].scope?.mentioned(in: "open find my and check where mom is") == true, "app scope matches its app and mentions")
        check(parsed[2].scope == Memory.Scope(kind: "site", name: "wellfound.com") && !parsed[2].tagged
              && parsed[2].scope?.matches(app: nil, host: "https://wellfound.com/jobs") == true
              && parsed[2].scope?.mentioned(in: "apply on wellfound") == true, "how-to line infers its site")
        check(parsed[3].scope == nil && parsed[4].scope == nil, "facts about the user stay unscoped (emails aren't sites)")
        check(parsed[0].scope?.matches(app: nil, host: "mail.google.com") == false, "a site scope doesn't leak to sibling subdomains")
        check(Memory.stem("ordering") == "order" && Memory.stem("orders") == "order" && Memory.stem("applies") == "apply"
              && Memory.stem("classes") == "class" && Memory.stem("bus") == "bus", "stemmer")
        let index = Memory.Index(["Orders food through Swiggy", "CGPA 8.96 at KJSCE", "Listens to lofi music on YouTube"])
        let hits = index.scores(Memory.expand("order me something to eat"), among: [0, 1, 2])
        check(hits.keys.sorted() == [0], "BM25 finds the ordering fact and nothing else")
        check(Memory.details("call +91 93267 70790 or mail a@b.co about 'Waje+'", quoted: true).count == 3, "details: phone, email, quoted name")
        let graph = MemoryGraph(Memory.parse("""
        - Mom's WhatsApp chat is named 'Mom ❤️'
        - His mother lives in Pune and prefers calls after 7pm
        - Likes lofi music
        - Sends invoices to billing@acme.dev every month
        - The billing@acme.dev inbox auto-replies on weekends
        """))
        check(graph.links[0].contains { $0.0 == 1 } && graph.links[3].contains { $0.0 == 4 } && graph.links[2].isEmpty,
              "memory graph links facts about the same person or detail, not unrelated ones")
        check(graph.spread(from: [(0, 1.0)], damping: 0.8)[1].map { $0 > 0.3 } == true, "activation spreads to a linked fact")
        let changes = [Memory.Change(at: Date(), old: "Phone is 1111", new: "Phone is 2222", why: "updated"),
                       Memory.Change(at: Date(), old: "Phone is 2222", new: "Phone is 3333", why: "updated")]
        check(Memory.earlier("Phone is 3333", in: changes) == ["Phone is 2222", "Phone is 1111"], "earlier versions follow the update chain")
        let old = Memory.parse("""
        # My memory
        * Likes lofi music
        1. Orders food through Swiggy
        - [ ] [app:Find My] open it as 'FindMy'
        <!-- note to self -->
        • Likes lofi music
        - Find My app: open it as 'FindMy'
        """)
        check(old.map(\.text) == ["Likes lofi music", "Orders food through Swiggy", "open it as 'FindMy'", "Likes lofi music", "Find My app: open it as 'FindMy'"]
              && old[2].tagged, "older and hand-written list styles parse (headings and comments skipped)")
        let (lines, merged) = Memory.normalized(old)
        check(lines == ["Orders food through Swiggy", "[app:Find My] open it as 'FindMy'", "Likes lofi music", "Find My app: open it as 'FindMy'"]
              && merged == ["Likes lofi music"], "upgrade merges exact duplicates, keeping the newest and its tag")
        if let enc = TextEncoder.load() {
            check(enc.tokens("Hello, world!") == [101, 7592, 1010, 2088, 999, 102], "retrieval model tokenizer (BERT WordPiece)")
            let a = enc.embed("That is a happy person"), b = enc.embed("That is a very happy person"), c = enc.embed("Today is a sunny day")
            check(Embedder.cosine(a, b) > 0.9 && Embedder.cosine(a, b) > Embedder.cosine(a, c) + 0.15, "retrieval model: close sentences are close")
        } else {
            print("     (retrieval model not downloaded: skipped its checks)")
        }
        check(Set(Agent.closest(to: "Application submitted", in: "Home\nYour application was sent · Thanks!\nApplication received"))
              == ["Your application was sent", "Application received"],
              "a missed wait shows the closest text on the page")
    }
    // Workflows: a saved run turns typed text into a named parameter with the original as default.
    MainActor.assumeIsolated {
        var type = WorkflowStep(action: "type"); type.text = "Amrit Nigam"
        type.target = .init(kind: "web", role: "text", label: "Your name")
        var click = WorkflowStep(action: "click"); click.target = .init(kind: "web", role: "checkbox", label: "Keynote")
        let entry = History.Entry(date: Date(), request: "fill the form", answer: "done", ok: true, steps: [], app: nil,
                                  result: nil, trace: [type, click])
        let wf = Workflow.from(entry)
        check(wf?.params == ["Your name"] && wf?.defaults?["Your name"] == "Amrit Nigam" && wf?.steps[0].text == "{Your name}",
              "saved workflow parameterizes typed text")
        let action = wf?.steps[0].action(params: ["Your name": "Priya"], id: "w5")
        check(action?["text"] as? String == "Priya" && action?["id"] as? String == "w5", "parameters fill in on replay")
    }
    // Workflow-first: a saved run replays for the same request, with typed values read out of the new words.
    MainActor.assumeIsolated {
        var type = WorkflowStep(action: "type"); type.text = "{Your name}"
        type.target = .init(kind: "web", role: "text", label: "Your name")
        var msg = WorkflowStep(action: "type"); msg.text = "{message}"
        let wf = Workflow(name: "Type Amrit Nigam as the name", summary: "", params: ["Your name"], steps: [type], created: Date(),
                          defaults: ["Your name": "Amrit Nigam"])
        let chat = Workflow(name: "message mom I'll be late", summary: "", params: ["message"], steps: [msg], created: Date(),
                            defaults: ["message": "I'll be late"])
        let open = Workflow(name: "open my github profile", summary: "", params: [], steps: [WorkflowStep(action: "open_url", url: "https://github.com")], created: Date())
        let all = [wf, chat, open]
        check(Router.match("type Priya Sharma as the name", in: all)?.params["Your name"] == "Priya Sharma", "workflow-first fills a parameter")
        check(Router.match("Please message mom I'm stuck in traffic.", in: all)?.params["message"] == "I'm stuck in traffic", "workflow-first: filler and punctuation ignored")
        check(Router.match("open my GitHub profile", in: all)?.workflow.name == "open my github profile", "workflow-first: exact request, no parameters")
        check(Router.match("open my github settings", in: all) == nil, "workflow-first: a different request doesn't match")
        check(Router.match("message dad I'll be late", in: all) == nil, "workflow-first: only parameters may differ")
        check(Router.refersToContext("reply to this") && Router.refersToContext("translate it") && !Router.refersToContext("open my github profile"), "requests about \"this\" need the model")
    }
    check(Router.isDismissal("no thanks") && Router.isDismissal("kuch nahi") && Router.isDismissal("bas")
          && !Router.isDismissal("now email that to Rahul"), "follow-up dismissals")
    check(Safety.isYes("haan ji") && Safety.isYes("theek hai") && Safety.isYes("bhej do") && !Safety.isYes("ji nahi") && !Safety.isYes("haan but don't send"),
          "Hinglish yes/no")
    // Dates for the calendar come as local "yyyy-MM-dd HH:mm".
    MainActor.assumeIsolated {
        let d = Events.date("2026-10-02 15:30")
        let c = d.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
        check(c?.year == 2026 && c?.month == 10 && c?.day == 2 && c?.hour == 15 && c?.minute == 30, "calendar date parsing")
        check(Events.date("2026-10-02") != nil && Events.date("next thursday") == nil, "date-only and nonsense dates")
    }
    // Tables: CSV round-trips quotes, commas and newlines.
    let rows = [["Vendor", "Note", "Amount"], ["Swiggy, Inc", "said \"hi\"\nthen left", "540"]]
    check(Tables.parse(Tables.csv(rows)) == rows, "CSV round trip")
    check(MainActor.assumeIsolated { Files.kindQuery("pdf").contains("com.adobe.pdf") && Files.kindQuery(".key").contains("*.key") }, "file kinds for Spotlight")
    // Scripting dictionaries: Notes should describe its note class and the make command.
    if let notes = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
        let sem = DispatchSemaphore(value: 0)
        var dict: String?
        // Close Notes again afterwards, unless it was already open.
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty
        Task.detached {
            let app = try? await NSWorkspace.shared.openApplication(at: notes, configuration: {
                let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.hides = true; return c }())
            if let app { dict = await Scripting.dictionary(for: app) }
            if !wasRunning { app?.terminate() }
            sem.signal()
        }
        sem.wait()
        check(dict?.contains("class note") == true && dict?.contains("make") == true, "Notes dictionary summary (\(dict?.count ?? 0) chars)")
    }
    // Stats: model vs action time per turn comes from agent.log's "turn N · <ms> ms" lines and step times.
    do {
        let runs = Stats.parse("""
        === fill the form
        [  0.30s]   page: Form · 10 elements
        [  2.30s] turn 0 · 2000 ms · {"say":"x"}
        [  2.40s]   → Type “Amrit”
        [  3.00s]     ✗ the text didn't land in w3
        [  5.50s] turn 1 · 2000 ms · {"say":"y"}
        [  5.60s]   → Click Next
        [  6.60s] ✓ Filled it
        """)
        let t = runs.first?.turns ?? []
        check(runs.count == 1 && t.count == 2 && t[0].actMs == 1200 && t[1].actMs == 1100 && runs[0].setupMs == 300
              && runs[0].stepFailures.count == 1 && runs[0].ok == true, "stats: per-turn model vs action time")
        check(Stats.reason("couldn't find “Next” (w12)") == Stats.reason("couldn't find “Submit” (w3)"), "stats: similar failures group")
        // Click lines: how often the first way worked, what rescued the rest, and where clicks struggle.
        let clicks = Stats.parse("""
        === tick things
        [  1.00s] \(Clicks.line(kind: "web", place: "forms.gle", method: "mouse", worked: true, tries: 1))
        [  2.00s] \(Clicks.line(kind: "web", place: "forms.gle", method: "script", worked: true, tries: 2))
        [  3.00s] \(Clicks.line(kind: "web", place: "forms.gle", method: "key", worked: false, tries: 3))
        [  4.00s] \(Clicks.line(kind: "ax", place: "Microsoft Teams", method: "axpress", worked: true, tries: 1))
        [  5.00s] ✓ done
        """).flatMap(\.clicks)
        let report = Stats.clickReport(clicks).joined(separator: "\n")
        check(clicks.count == 4 && report.contains("Clicks: 4 · worked first try 50% · needed another way 25% · no visible change 25%")
              && report.contains("forms.gle 2/3") && report.contains("script 1"), "stats: click report")
    }
    // Safety: a "don't" about any of a control's words wins over another word the request used ("Easy Apply").
    check(Safety.needsConfirmation(label: "Submit application", request: "fill the Easy Apply form but don't submit it") != nil
          && Safety.needsConfirmation(label: "Submit application", request: "fill the easy apply form, don’t submit") != nil
          && Safety.needsConfirmation(label: "Submit application", request: "apply to this job with my details") == nil, "negated verb blocks submit")
    check(Safety.blockedChord("cmd+ctrl+q", request: "open spotify") != nil && Safety.blockedChord("ctrl+cmd+q", request: "lock my screen") == nil
          && Safety.blockedChord("cmd+ctrl+q", request: "set a clock alarm") != nil && Safety.blockedChord("cmd+q", request: "quit notes") == nil,
          "session-ending chords only when asked")
    // Desktop diffs: what changed by stable ref, and none at all once positional ids have shifted.
    do {
        let el = AXUIElementCreateApplication(getpid())
        func e(_ i: Int, _ role: String, _ label: String, _ ref: String, _ value: String? = nil) -> UIElementInfo {
            UIElementInfo(id: "e\(i)", role: role, label: label, frame: .zero, element: el, ref: ref, value: value)
        }
        let before = [e(0, "AXButton", "Send", "a"), e(1, "AXTextField", "Message", "b", "h"), e(2, "AXButton", "Old", "c")]
        let after = [e(0, "AXButton", "Send", "a"), e(1, "AXTextField", "Message", "b", "hi"), e(2, "AXButton", "Cancel", "d")]
        let d = ScreenDiff.between(before, after)
        let text = d.text()
        check(d.changed.count == 1 && d.added.count == 1 && d.removed.count == 1 && text.contains("~ e1 TextField value 'h'→'hi'")
              && text.contains("+ e2 Button 'Cancel'") && text.contains("- e2 Button 'Old'"), "screen diff by ref")
        check(ScreenDiff.listingUpdate(from: before, to: after) != nil && ScreenDiff.listingUpdate(from: before, to: before) == ""
              && ScreenDiff.listingUpdate(from: before, to: [e(0, "AXButton", "New", "z")] + after.map { e(Int($0.id.dropFirst())! + 1, $0.role, $0.label, $0.ref, $0.value) }) == nil,
              "desktop diff only while e-ids hold")
    }
    // Web diffs: stable w-ids compared by key; another page gets the full listing.
    MainActor.assumeIsolated {
        typealias B = BrowserBridge
        func el(_ i: Int, _ role: String, _ text: String, _ value: String? = nil) -> B.PageElement {
            B.PageElement(index: i, role: role, text: text, rect: .zero, editable: role == "textbox", extra: "", key: "|\(role)|\(text)", value: value)
        }
        func page(_ url: String, _ els: [B.PageElement]) -> B.Page {
            B.Page(connection: ObjectIdentifier(Agent.self), url: url, title: "Apply", viewport: CGSize(width: 1, height: 1), scrollY: 0,
                   scrollMax: 0, headings: [], elements: els, estimatedArea: nil)
        }
        let before = page("https://x.com/apply?step=1", [el(1, "textbox", "Name", ""), el(2, "button", "Next"), el(3, "link", "Jobs")])
        let after = page("https://x.com/apply?step=2", [el(1, "textbox", "Name", "Amrit"), el(2, "button", "Next"), el(5, "button", "Dismiss")])
        let d = B.diff(previous: before, current: after) ?? "nil"
        check(d.contains("~ w1") && d.contains("+ w5 button: Dismiss") && d.contains("- w3 link: Jobs") && !d.contains("w2"), "page diff by stable id")
        check(B.diff(previous: before, current: page("https://x.com/other", after.elements)) == nil, "another page gets the full listing")
    }
    // Autofill: one plan for every visible field the profile answers; the rest is listed for the model.
    MainActor.assumeIsolated {
        typealias B = BrowserBridge
        func f(_ i: Int, _ role: String, _ text: String, q: String? = nil, value: String? = nil, options: [String] = [],
               flags: Set<String> = [], dropdown: Bool = false) -> B.PageElement {
            B.PageElement(index: i, role: role, text: text, rect: .zero, editable: !["radio", "button", "file"].contains(role), extra: "",
                          key: "|\(role)|\(text)", value: value, flags: flags, question: q, options: options, dropdown: dropdown)
        }
        let form = B.Page(connection: ObjectIdentifier(Agent.self), url: "https://jobs.lever.co/acme/apply", title: "Apply", viewport: CGSize(width: 1, height: 1),
                          scrollY: 0, scrollMax: 0, headings: [], elements: [
            f(1, "text", "Full name *"), f(2, "email", "Email", value: "already@there.com"), f(3, "select", "Notice period", value: "Select…",
            options: ["Select…", "Immediately", "15 days", "30 days"]), f(4, "radio", "Yes", q: "Willing to relocate?"),
            f(5, "radio", "No", q: "Willing to relocate?"), f(6, "textarea", "Why Acme?", flags: ["required"]),
            f(7, "file", "Resume"), f(8, "button", "Submit application"), f(9, "select", "Experience", value: "", options: ["0-6 months", "18 months"]),
        ], estimatedArea: nil)
        let answers = ["full name": "Amrit Nigam", "email": "a@b.co", "notice period": "Immediate", "willing to relocate?": "Yes (Bangalore)",
                       "experience": "8 months"]
        let plan = FormFill.plan(form) { answers[$0.lowercased()] }
        let did = plan.steps.map { "\($0.action["do"]!) \($0.action["id"]!) \($0.answer)" }
        check(did == ["type w1 Amrit Nigam", "choose w3 Immediately", "click w4 Yes"], "autofill plans typing, a dropdown and a radio (\(did))")
        check(plan.open.contains("Why Acme? (required)") && plan.open.contains { $0.hasPrefix("Experience") } && plan.uploads == 1,
              "autofill leaves unanswered and unmatched questions to the model")
        check(FormFill.bestOption("8 months", in: ["18 months", "6-12 months"]) == nil && FormFill.bestOption("No", in: ["Yes", "No, I don't"]) == "No, I don't"
              && FormFill.bestOption("Immediate", in: ["Immediately", "1 month"]) == "Immediately", "autofill option matching is whole-word")
    }
    // Streaming: the first action is read out of a half-written reply once it's complete, and only then.
    MainActor.assumeIsolated {
        let full = #"```json\n{"say":"Filling","actions":[{"do":"type","id":"w3","text":"a {brace} and \"quote\""},{"do":"click","id":"w9"}],"done":false}"#
        let cut = full.firstIndex(of: "}").map { full[...$0] }.map(String.init) ?? ""   // ends inside the first action's text
        check(Brain.firstAction(inPartial: #"{"say":"Fill"#) == nil && Brain.firstAction(inPartial: cut) == nil,
              "streaming: nothing until the first action is complete")
        let first = Brain.firstAction(inPartial: String(full.prefix(full.range(of: "{\"do\":\"click")!.lowerBound.utf16Offset(in: full))))
        check(first?["do"] as? String == "type" && first?["text"] as? String == "a {brace} and \"quote\"", "streaming: first action parsed past braces and quotes in strings")
        check(Agent.startsEarly(["do": "read"]) && !Agent.startsEarly(["do": "click", "id": "w1"]) && !Agent.startsEarly(["do": "type", "id": "w1", "text": "x"]) && !Agent.startsEarly(["do": "ask", "question": "?"]) && !Agent.startsEarly(["do": "email"]),
              "streaming: only on-screen steps start early")
        check(Agent.canonical(["b": 1, "a": "x"]) == Agent.canonical(["a": "x", "b": 1]), "streaming: actions compare by content")
    }
    // Job profile: fields answer their questions; a saved earlier answer wins for its own question.
    do {
        var p = Profile.Data()
        p.name = "Amrit Nigam"; p.expectedCTC = "6 LPA"; p.noticePeriod = "Immediate"; p.linkedin = "https://linkedin.com/in/amrit"
        p.qa = [Profile.QA(question: "Why do you want to join us?", answer: "I like the product")]
        check(Profile.answer(for: "Expected CTC (per annum)", in: p) == "6 LPA" && Profile.answer(for: "Notice period", in: p) == "Immediate"
              && Profile.answer(for: "LinkedIn profile URL", in: p) == p.linkedin && Profile.answer(for: "First name", in: p) == "Amrit"
              && Profile.answer(for: "Why do you want to join us?", in: p) == "I like the product"
              && Profile.answer(for: "Years of experience with Kubernetes", in: p) == nil, "profile answers form questions")
    }
    MainActor.assumeIsolated {
        check(Agent.profileAnswer(for: ["question": "Which session did you attend, and how was it? I'll enter your name as Amrit Nigam.",
                                        "options": ["Keynote · Great", "Swift workshop · Great"]]) == nil,
              "profile: a side remark about the name doesn't answer a choice question")
    }
    check(!Agent.acts("radio") && !Agent.acts("AXCheckBox") && !Agent.acts("option") && Agent.acts("button") && Agent.acts("link")
          && Agent.acts("AXButton"), "risky-click confirmation only for controls that act")
    check(Agent.saysUnfinished("Steps 1–6 partly done: instance launched. Still to do: attach role, SSH check, SNS, alarm")
          && !Agent.saysUnfinished("Subscription created; it's pending until you click the confirm link in the AWS email.")
          && !Agent.saysUnfinished("Added the CloudWatch alarm steps to the Arc doc."), "done with work left isn't done")
    check(Agent.saysUnfinished("Done through RDS creation and ECR repo; bastion SSH, ECS, ALB, pipeline, SNS and the doc remain")
          && Agent.saysUnfinished("I got through Steps 1–6 of the 15 and stopped there.")
          && !Agent.saysUnfinished("The instance will remain running until you stop it."), "lab summaries with steps left aren't done")
    check(Agent.snapCaption("Step 3: RDS created", number: 5) == "Step 3: RDS created"
          && Agent.snapCaption("RDS created", number: 5) == "Step 5: RDS created"
          && Agent.snapCaption("", number: 2) == "Step 2", "snap captions keep the guide's step number, no double numbering")
    check(Agent.wordsInOrder("Policy created", in: "Policy lab7-codebuild-ecr created.")
          && !Agent.wordsInOrder("Policy created", in: "Policy name")
          && !Agent.wordsInOrder("created", in: "Time created"), "wait matches the message with a name in it")
    check(Agent.keepsFrontApp("open Spotify") && Agent.keepsFrontApp("show me my calendar") && Agent.keepsFrontApp("please search flights to Goa")
          && !Agent.keepsFrontApp("type hello into the open TextEdit document") && !Agent.keepsFrontApp("reply to Anmol that I'm on my way"),
          "front app: kept for open/show/search requests only")
    check(!Agent.isConfirmation("What should I put for Notice period?") && Agent.isConfirmation("Should I submit the form?")
          && !Agent.isConfirmation("Who should I put as the referrer's name? (I won't submit the form yet.)")
          && Agent.isConfirmation("Ready to submit?"), "confirmation vs a question for a detail")
    check(!Agent.asksForPersonalDetails("Which session did you attend, and how was it? (I'll use the name Amrit Nigam.)")
          && Agent.asksForPersonalDetails("What's your full name?") && Agent.asksForPersonalDetails("What is your phone number?"),
          "personal-detail questions: the detail right after “your”")
    check(Agent.isFormSubmit("Submit application") && Agent.isFormSubmit("Send application") && !Agent.isFormSubmit("Easy Apply to this job"),
          "form submit buttons")
    // Replay: recorded page snapshots + replies re-checked offline (tests/replay/*.json).
    MainActor.assumeIsolated {
        guard let dir = Replay.repoFixtures else { print("skip replay fixtures (no tests/replay here)"); return }
        for url in Replay.fixtures(at: dir) {
            let r = Replay.run(url)
            r.failures.forEach { print("     \($0)") }
            check(r.checks > 0 && r.failures.isEmpty, "replay \(url.lastPathComponent) (\(r.checks) checks)")
        }
    }
    print(failures == 0 ? "all passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

// `Clinqy --snapshots`: what each connected browser reports for its active tab (debugging the extension).
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--snapshots" {
    Task { @MainActor in
        BrowserBridge.shared.start()
        try? await Task.sleep(for: .seconds(23))   // every browser reconnects within 20 s
        for line in await BrowserBridge.shared.debugSnapshots() { print(line) }
        exit(0)
    }
    RunLoop.main.run()
}

// `Clinqy --reload-extension`: reloads the browser extension everywhere it's connected.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--reload-extension" {
    Task { @MainActor in
        BrowserBridge.shared.start()
        try? await Task.sleep(for: .seconds(22))   // browsers reconnect every 20 s
        print("reloaded in \(await BrowserBridge.shared.reloadAll()) browser(s)")
        exit(0)
    }
    RunLoop.main.run()
}

let app = ClinqyApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
