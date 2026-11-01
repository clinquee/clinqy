import AppKit

@MainActor private final class WorkerActivationLog { var pids: [pid_t] = [] }

@main struct ChromeWorkerTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-worker-tests-\(UUID())")
        let worker = ChromeWorker(root: root.appendingPathComponent("worker"))
        let other = ChromeWorker(root: root.appendingPathComponent("other"))
        let recovered = ChromeWorker(root: root.appendingPathComponent("worker"))
        let activations = WorkerActivationLog()
        var ownedPIDs: Set<pid_t> = []
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                         object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    activations.pids.append(app.processIdentifier)
                }
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        func rememberPID(_ profile: String) throws {
            let data = try Data(contentsOf: root.appendingPathComponent(profile + "/owner.json"))
            let owner = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            ownedPIDs.insert(pid_t(owner["pid"] as! Int))
        }
        var observations: [ObjectIdentifier: [Int: [String: Any]]] = [:]
        func command(_ owner: ChromeWorker, _ name: String, tabID: Int?, args: [String: Any] = [:]) async throws -> [String: Any] {
            var parameters = args
            if let tabID, let token = observations[owner.identity]?[tabID] {
                parameters.merge(token) { _, new in new }
            }
            let result = try await owner.command(name, tabID: tabID, args: parameters)
            if name == "snapshot", let tabID, let document = result["documentID"], let snapshot = result["snapshotID"] {
                observations[owner.identity, default: [:]][tabID] = ["documentID": document, "snapshotID": snapshot]
            }
            return result
        }
        let clipboard = NSPasteboard.general.changeCount
        var checks = 0
        func check(_ value: Bool, _ label: String) throws { guard value else { throw WorkerCDP.error(label) }; checks += 1 }
        func page(_ label: String) -> String {
            let html = "<button onclick=\"const field=document.createElement('input');field.setAttribute('aria-label','Dynamic field');document.body.append(field)\">Add field</button><title>\(label)</title><nav><img src='http://127.0.0.1:1/nav.png' width='90' height='70'></nav><img src='http://127.0.0.1:1/article.png' alt='Article image' width='90' height='70'><img src='http://127.0.0.1:1/icon.png' width='16' height='16'><label>Name<input id='name'></label><label>Resume<input id='upload' type='file' onchange=\"setTimeout(async()=>{document.querySelector('#uploadStatus').textContent=await this.files[0].text()},100)\"></label><button onclick=\"document.querySelector('#upload').click()\">Attach sample</button><p id='uploadStatus'></p><button onclick=\"document.body.dataset.sent='yes';this.textContent='Confirmed'\">Submit sample</button>"
            return "data:text/html;base64," + Data(html.utf8).base64EncodedString()
        }
        do {
            worker.runStarted()
            other.runStarted()
            let firstURL = page("Worker"), secondURL = page("Concurrent browser")
            async let first = worker.newTab(firstURL)
            async let second = other.newTab(secondURL)
            let (id, otherID) = try await (first, second)
            try rememberPID("worker"); try rememberPID("other")
            let sourceAURL = page("Delegated source A"), sourceBURL = page("Delegated source B")
            async let sourceA = worker.newTab(sourceAURL, select: false)
            async let sourceB = worker.newTab(sourceBURL, select: false)
            let (sourceAID, sourceBID) = try await (sourceA, sourceB)
            try check(sourceAID != sourceBID && sourceAID != id, "parallel source tabs have distinct owned IDs")
            let tabList = try await worker.command("tabs", tabID: nil)["tabs"] as? [[String: Any]] ?? []
            try check(tabList.first(where: { $0["active"] as? Bool == true })?["id"] as? Int == id,
                      "delegated source tabs don't replace the lead's selected tab")
            async let sourceASnapshot = command(worker, "snapshot", tabID: sourceAID)
            async let sourceBSnapshot = command(worker, "snapshot", tabID: sourceBID)
            _ = try await (sourceASnapshot, sourceBSnapshot)
            async let sourceAText = command(worker, "read", tabID: sourceAID)
            async let sourceBText = command(worker, "read", tabID: sourceBID)
            let (aText, bText) = try await (sourceAText, sourceBText)
            try check((aText["text"] as? String)?.contains("Name") == true && (bText["text"] as? String)?.contains("Name") == true,
                      "parallel reads are pinned to their source tabs")
            _ = try await worker.command("closeTab", tabID: sourceAID)
            _ = try await worker.command("closeTab", tabID: sourceBID)
            let leadTab = try await worker.command("tabInfo", tabID: id)
            try check(leadTab["title"] as? String == "Worker", "source-tab cleanup preserves the lead's task")
            try await Task.sleep(for: .milliseconds(500))
            let snap = try await command(worker, "snapshot", tabID: id)
            let imageList = try await command(worker, "images", tabID: id)["images"] as? [[String: Any]] ?? []
            try check(imageList.count == 1 && imageList[0]["alt"] as? String == "Article image", "real browser image discovery excludes navigation and icons")
            try check(imageList.first?["url"] as? String == "http://127.0.0.1:1/article.png", "real browser image source addresses are exposed without focus")
            let elements = snap["elements"] as? [[String: Any]] ?? []
            let name = elements.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }?["i"] as? Int
            try check(name != nil, "snapshots owned form")
            _ = try await command(worker, "fill", tabID: id, args: ["index": name!, "text": "Background only"])
            let review = try await command(worker, "review", tabID: id)
            try check(String(describing: review).contains("Background only"), "reviews actual field value")
            _ = try await command(worker, "focus", tabID: id, args:["index": name!])
            _ = try await command(worker, "cdpKey", tabID: id, args:["keys":"cmd+a"])
            _ = try await command(worker, "cdpType", tabID: id, args:["text":"Trusted worker input"])
            let typed = try await command(worker, "value", tabID: id, args:["index":name!])
            try check(typed["value"] as? String == "Trusted worker input", "trusted input stays in worker field")
            let batch = try await command(worker, "values", tabID: id, args: ["indices": [name!]])
            try check((batch["values"] as? [String: Any])?[String(name!)] as? String == "Trusted worker input", "batched field checks read current values")
            let add = elements.first { ($0["text"] as? String ?? "") == "Add field" }!["i"] as! Int
            _ = try await command(worker, "click", tabID: id, args: ["index": add])
            let changedDOM = try await command(worker, "snapshot", tabID: id)
            try check((changedDOM["elements"] as? [[String: Any]])?.contains { $0["text"] as? String == "Dynamic field" } == true, "candidate cache invalidates when the DOM adds a control")
            let slowRead = Task { try await command(worker, "waitText", tabID: id, args: ["text": "fixture-that-never-appears", "ms": 5_000]) }
            try await Task.sleep(for: .milliseconds(40))
            let cancelledAt = Date(); slowRead.cancel()
            do { _ = try await slowRead.value; preconditionFailure("cancelled CDP read completed") } catch { checks += 1 }
            try check(Date().timeIntervalSince(cancelledAt) < 1, "cancelled browser commands return promptly")
            let submit = elements.first { ($0["text"] as? String ?? "").contains("Submit sample") }!["i"] as! Int
            _ = try await command(worker, "click", tabID: id, args:["index":submit])
            let sent = try await command(worker, "read", tabID: id)
            try check((sent["text"] as? String ?? "").contains("Confirmed"), "clicks and confirms local sample submission")
            let file = elements.first { $0["role"] as? String == "file" || ($0["text"] as? String ?? "").contains("Resume") }?["i"] as? Int
            var args: [String: Any] = ["name":"sample.txt", "type":"text/plain", "data":Data("test attachment".utf8).base64EncodedString()]
            if let file { args["index"] = file }
            let upload = try await command(worker, "upload", tabID: id, args: args)
            try check(upload["ok"] as? Bool == true, "uploads bytes without host picker")
            let attach = elements.first { ($0["text"] as? String ?? "").contains("Attach sample") }!["i"] as! Int
            var via = args; via["index"] = attach
            let chooser = try await command(worker, "uploadVia", tabID: id, args:via)
            try check(chooser["ok"] as? Bool == true, "intercepts file chooser without opening Finder")
            var uploadRead: [String: Any] = [:]
            // Chrome may throttle a background page's 100 ms timer to one second.
            for _ in 0..<30 {
                uploadRead = try await command(worker, "read", tabID: id)
                if (uploadRead["text"] as? String ?? "").contains("test attachment") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try check((uploadRead["text"] as? String ?? "").contains("test attachment"), "uploaded file remains readable after picker returns")
            let photo = try await command(worker, "captureTask", tabID: id)
            try check((photo["image"] as? String)?.isEmpty == false, "captures owned task screenshot")
            let png = Data(base64Encoded: photo["image"] as! String)!
            try check(Array(png.prefix(4)) == [137, 80, 78, 71], "exported screenshot remains PNG")
            let preview = try await command(worker, "capturePreview", tabID: id)
            let jpeg = Data(base64Encoded: preview["image"] as! String)!
            try check(Array(jpeg.prefix(2)) == [255, 216], "live preview uses JPEG")
            let bitmap = NSBitmapImageRep(data: jpeg)
            try check(bitmap?.pixelsWide == 1440 && bitmap?.pixelsHigh == 900, "preview preserves the full viewport")
            if let sample = ProcessInfo.processInfo.environment["CLINQY_TEST_PREVIEW"] {
                try jpeg.write(to: URL(fileURLWithPath: sample))
            }
            let vision = try await command(worker, "captureVision", tabID: id)
            try check(Array(Data(base64Encoded: vision["image"] as! String)!.prefix(2)) == [255, 216], "model screenshot matches JPEG media type")
            let otherSnap = try await command(other, "snapshot", tabID: otherID)
            let otherEls = otherSnap["elements"] as? [[String: Any]] ?? []
            let otherName = otherEls.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            let otherValue = try await command(other, "value", tabID: otherID, args:["index":otherName])
            try check(otherValue["value"] as? String == "", "concurrent browser field unchanged")
            do { _ = try await command(worker, "snapshot", tabID: -99); preconditionFailure("accepted unowned tab") } catch { checks += 1 }
            do { _ = try await command(worker, "cdpKey", tabID: id, args:["keys":"cmd+v"]); preconditionFailure("accepted shared clipboard shortcut") } catch { checks += 1 }
            let navigated = try await worker.newTab(page("Before navigation"))
            _ = try await command(worker, "snapshot", tabID: navigated)
            _ = try await command(worker, "navigate", tabID: navigated, args: ["url": page("After navigation")])
            try await Task.sleep(for: .milliseconds(500))
            let nextSnapshot = try await command(worker, "snapshot", tabID: navigated)
            try check(nextSnapshot["title"] as? String == "After navigation", "reinstalls page helpers after navigation")
            let embeddedHTML = "<title>Embedded form</title><iframe srcdoc=\"<label>Embedded name<input></label>\"></iframe><iframe srcdoc=\"<label>Second name<input></label>\"></iframe>"
            let embedded = try await worker.newTab("data:text/html;base64," + Data(embeddedHTML.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            let embeddedSnapshot = try await command(worker, "snapshot", tabID: embedded)
            let embeddedElements = embeddedSnapshot["elements"] as? [[String: Any]] ?? []
            let embeddedField = embeddedElements.first { ["textbox", "text"].contains($0["role"] as? String ?? "") }?["i"] as? Int
            try check(embeddedField != nil, "snapshots embedded frame with cached helpers")
            _ = try await command(worker, "fill", tabID: embedded, args: ["index": embeddedField!, "text": "Inside frame"])
            let embeddedValue = try await command(worker, "value", tabID: embedded, args: ["index": embeddedField!])
            try check(embeddedValue["value"] as? String == "Inside frame", "cached frame context routes actions to the right document")
            let frameFields = embeddedElements.filter { ["textbox", "text"].contains($0["role"] as? String ?? "") }.compactMap { $0["i"] as? Int }
            try check(frameFields.count == 2, "concurrent snapshots include both embedded frames")
            let frameBatch = try await command(worker, "values", tabID: embedded, args: ["indices": frameFields])
            let frameValues = frameBatch["values"] as? [String: Any] ?? [:]
            try check(frameValues[String(embeddedField!)] as? String == "Inside frame" && frameValues.count == 2, "batch reads stay pinned to the correct iframe")
            // Freshness tokens must bind a command to the exact document/listing, not just a URL or label.
            let fixture = "<title>Freshness</title><button id='target' onclick=\"document.querySelector('#result').textContent+='target;'\">Duplicate</button><button onclick=\"document.querySelector('#result').textContent+='second;'\">Duplicate</button><button onclick=\"const n=document.querySelector('#target');n.replaceWith(n.cloneNode(true))\">Replace target</button><button onclick=\"document.querySelector('#target').style.marginLeft='60px'\">Move target</button><button onclick=\"const ds=[...document.querySelectorAll('button')].filter(b=>b.textContent==='Duplicate');ds[0].before(ds[1])\">Reorder duplicates</button><p id='result'></p><iframe srcdoc=\"<label>Frame field<input></label>\"></iframe><button onclick=\"const f=document.querySelector('iframe');f.srcdoc=f.srcdoc\">Reload frame</button>"
            let fixtureURL = "data:text/html;base64," + Data(fixture.utf8).base64EncodedString()
            let freshID = try await worker.newTab(fixtureURL)
            try await Task.sleep(for: .milliseconds(300))
            func token(_ snapshot: [String: Any], _ args: [String: Any] = [:]) -> [String: Any] {
                args.merging(["documentID": snapshot["documentID"]!, "snapshotID": snapshot["snapshotID"]!]) { _, new in new }
            }
            func index(_ snapshot: [String: Any], _ text: String, occurrence: Int = 0) -> Int {
                let matching = (snapshot["elements"] as! [[String: Any]]).filter { $0["text"] as? String == text }
                return matching[occurrence]["i"] as! Int
            }
            func reject(_ name: String, snapshot: [String: Any]?, args: [String: Any], label: String) async throws {
                do {
                    _ = try await worker.command(name, tabID: freshID, args: snapshot.map { token($0, args) } ?? args)
                } catch { checks += 1; return }
                try check(false, label)
            }
            let seen = try await command(worker, "snapshot", tabID: freshID)
            try check(seen["documentID"] as? String != nil && seen["snapshotID"] as? String != nil, "snapshot returns document and listing tokens")
            try await reject("click", snapshot: nil, args: ["index": index(seen, "Duplicate")], label: "unguarded input rejected")
            let newer = try await command(worker, "snapshot", tabID: freshID)
            try check(seen["documentID"] as? String == newer["documentID"] as? String && seen["snapshotID"] as? String != newer["snapshotID"] as? String, "same document has fresh listing revision")
            try await reject("click", snapshot: seen, args: ["index": index(seen, "Duplicate")], label: "superseded listing rejected")
            _ = try await worker.command("click", tabID: freshID, args: token(newer, ["index": index(newer, "Replace target")]))
            let dead = try await worker.command("alive", tabID: freshID, args: token(newer, ["index": index(newer, "Duplicate")]))
            try check(dead["ok"] as? Bool == false, "identical DOM replacement does not resurrect old target")
            try await reject("click", snapshot: newer, args: ["index": index(newer, "Duplicate")], label: "cannot click replacement through old node")
            var afterReplacement = try await command(worker, "snapshot", tabID: freshID)
            let oldDuplicate = (newer["elements"] as! [[String: Any]]).first { $0["i"] as? Int == index(newer, "Duplicate") }!
            let replacementDuplicate = (afterReplacement["elements"] as! [[String: Any]]).first { $0["i"] as? Int == index(afterReplacement, "Duplicate") }!
            try check(oldDuplicate["key"] as? String != replacementDuplicate["key"] as? String, "new identical node gets new immutable identity across listings")
            let beforeMove = try await worker.command("locate", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Duplicate")]))
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Move target")]))
            let stillAlive = try await worker.command("alive", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Duplicate")]))
            try check(stillAlive["ok"] as? Bool == true, "same live node survives irrelevant layout change")
            try await reject("cdpClick", snapshot: afterReplacement,
                             args: ["index": index(afterReplacement, "Duplicate"), "x": beforeMove["px"]!, "y": beforeMove["py"]!], label: "old coordinate cannot click moved target")
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Duplicate", occurrence: 1)]))
            let duplicateResult = try await worker.command("read", tabID: freshID, args: token(afterReplacement))
            try check((duplicateResult["text"] as? String ?? "").contains("second;") && !(duplicateResult["text"] as? String ?? "").contains("target;"), "duplicate labels retain exact observed node identity")
            let orderedDuplicates = (afterReplacement["elements"] as! [[String: Any]]).filter { $0["text"] as? String == "Duplicate" }
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Reorder duplicates")]))
            afterReplacement = try await command(worker, "snapshot", tabID: freshID)
            let reversedDuplicates = (afterReplacement["elements"] as! [[String: Any]]).filter { $0["text"] as? String == "Duplicate" }
            try check(orderedDuplicates[0]["key"] as? String == reversedDuplicates[1]["key"] as? String && orderedDuplicates[1]["key"] as? String == reversedDuplicates[0]["key"] as? String, "identical-label reordering preserves each actual node key")
            try check(orderedDuplicates[0]["i"] as? Int == reversedDuplicates[1]["i"] as? Int && orderedDuplicates[1]["i"] as? Int == reversedDuplicates[0]["i"] as? Int, "reordered duplicate nodes retain their exact w IDs")
            let frameElement = (afterReplacement["elements"] as! [[String: Any]]).first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            _ = try await worker.command("click", tabID: freshID, args: token(afterReplacement, ["index": index(afterReplacement, "Reload frame")]))
            try await Task.sleep(for: .milliseconds(300))
            try await reject("fill", snapshot: afterReplacement, args: ["index": frameElement, "text": "must not type"], label: "iframe document reload rejects old field")
            try await reject("cdpType", snapshot: afterReplacement, args: ["text": "must not type"], label: "trusted typing rejects replaced embedded document")
            try await reject("cdpKey", snapshot: afterReplacement, args: ["keys": "x"], label: "trusted key rejects replaced embedded document")
            try await reject("cdpScroll", snapshot: afterReplacement, args: ["dy": 100], label: "trusted scroll rejects replaced embedded document")
            let frameReloaded = try await command(worker, "snapshot", tabID: freshID)
            let freshFrameField = (frameReloaded["elements"] as! [[String: Any]]).first { ["textbox", "text"].contains($0["role"] as? String ?? "") }!["i"] as! Int
            let untouchedFrame = try await worker.command("value", tabID: freshID, args: token(frameReloaded, ["index": freshFrameField]))
            try check(untouchedFrame["value"] as? String == "", "rejected global inputs leave replacement iframe empty")
            _ = try await worker.command("navigate", tabID: freshID, args: ["url": fixtureURL])
            try await Task.sleep(for: .milliseconds(300))
            try await reject("click", snapshot: afterReplacement, args: ["index": index(afterReplacement, "Duplicate")], label: "same-URL document reload rejects input before refresh")
            let reloaded = try await command(worker, "snapshot", tabID: freshID)
            try check(reloaded["documentID"] as? String != afterReplacement["documentID"] as? String, "same-URL reload changes document identity")
            try await reject("click", snapshot: afterReplacement, args: ["index": index(afterReplacement, "Duplicate")], label: "same-URL old token rejected after new listing")
            let untouched = try await worker.command("read", tabID: freshID, args: token(reloaded))
            try check(!(untouched["text"] as? String ?? "").contains("second;"), "stale commands left replacement document untouched")
            let optionsHTML = "<title>Option targets</title><div role='listbox' aria-label='Choice'><div id='alpha' role='option' onclick=\"document.querySelector('#picked').textContent='Alpha selected'\">Alpha</div><div role='option'>Duplicate option</div><div role='option'>Duplicate option</div></div><button onclick=\"const n=document.querySelector('#alpha');n.replaceWith(n.cloneNode(true))\">Replace option</button><p id='picked'></p>"
            let optionsID = try await worker.newTab("data:text/html;base64," + Data(optionsHTML.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            let optionSnapshot = try await command(worker, "snapshot", tabID: optionsID)
            let choice = (optionSnapshot["elements"] as! [[String: Any]]).first { $0["role"] as? String == "listbox" }!["i"] as! Int
            let option = try await worker.command("findOption", tabID: optionsID, args: token(optionSnapshot, ["index": choice, "text": "Alpha"]))
            try check(option["found"] as? Bool == true && option["pointToken"] as? String != nil, "option resolution returns node-bound token")
            let ambiguous = try await worker.command("findOption", tabID: optionsID, args: token(optionSnapshot, ["index": choice, "text": "Duplicate option"]))
            try check(ambiguous["found"] as? Bool == false, "ambiguous identical option labels rejected")
            _ = try await worker.command("click", tabID: optionsID, args: token(optionSnapshot, ["index": index(optionSnapshot, "Replace option")]))
            do {
                _ = try await worker.command("clickOption", tabID: optionsID, args: token(optionSnapshot, ["pointToken": option["pointToken"]!, "pointFrame": option["pointFrame"]!]))
                try check(false, "replaced option rejected")
            } catch { checks += 1 }
            let optionNow = try await worker.command("findOption", tabID: optionsID, args: token(optionSnapshot, ["index": choice, "text": "Alpha"]))
            _ = try await worker.command("clickOption", tabID: optionsID, args: token(optionSnapshot, ["pointToken": optionNow["pointToken"]!, "pointFrame": optionNow["pointFrame"]!]))
            let optionReadback = try await worker.command("read", tabID: optionsID, args: token(optionSnapshot))
            try check((optionReadback["text"] as? String ?? "").contains("Alpha selected"), "atomic option click applies to exact current candidate")
            do {
                _ = try await worker.command("clickOption", tabID: optionsID, args: token(optionSnapshot, ["pointToken": optionNow["pointToken"]!, "pointFrame": optionNow["pointFrame"]!]))
                try check(false, "option token cannot replay an input")
            } catch { checks += 1 }
            let multiFile = "<label>First attachment<input type='file'></label><label>Second attachment<input type='file'></label>"
            let multiID = try await worker.newTab("data:text/html;base64," + Data(multiFile.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            let multiSnapshot = try await command(worker, "snapshot", tabID: multiID)
            let fileFields = (multiSnapshot["elements"] as! [[String: Any]]).filter { $0["role"] as? String == "file" }
            let secondFile = fileFields.first { ($0["text"] as? String ?? "").contains("Second") }!["i"] as! Int
            let fileArgs: [String: Any] = ["name": "exact.txt", "type": "text/plain", "data": Data("exact input".utf8).base64EncodedString()]
            do {
                _ = try await worker.command("upload", tabID: multiID, args: token(multiSnapshot, fileArgs))
                try check(false, "ambiguous global upload rejected")
            } catch { try check(error.localizedDescription.contains("ambiguous"), "ambiguous upload error is explicit and pre-delivery") }
            _ = try await worker.command("upload", tabID: multiID, args: token(multiSnapshot, fileArgs.merging(["index": secondFile]) { _, new in new }))
            let uploadReview = try await worker.command("review", tabID: multiID, args: token(multiSnapshot))
            let uploadItems = uploadReview["items"] as! [[String: Any]]
            try check(uploadItems.first { ($0["q"] as? String ?? "").contains("First") }?["answer"] as? String == "", "unrelated file input remains empty")
            try check((uploadItems.first { ($0["q"] as? String ?? "").contains("Second") }?["answer"] as? String ?? "").contains("exact.txt"), "upload reaches exact selected file input")
            let gesturesHTML = """
            <title>Pointer gestures</title><style>button{padding:20px;margin:10px}#drop{display:inline-block;padding:30px;border:1px solid}</style>
            <button id='hover' onmouseenter="document.querySelector('#result').textContent='Hint revealed'">Hover target</button>
            <button oncontextmenu="event.preventDefault();document.querySelector('#result').textContent='Context opened'">Context target</button>
            <button ondblclick="document.querySelector('#result').textContent='Details opened'">Double target</button>
            <button onmousedown="window.dragging=true">Drag source</button><div id='drop' role='button' aria-label='Drop target'
            onmouseup="if(window.dragging)document.querySelector('#result').textContent='Card dropped';window.dragging=false">Drop target</div><p id='result'></p>
            """
            let gestureID = try await worker.newTab("data:text/html;base64," + Data(gesturesHTML.utf8).base64EncodedString())
            try await Task.sleep(for: .milliseconds(300))
            for (kind, label, expected) in [("hover", "Hover target", "Hint revealed"), ("right_click", "Context target", "Context opened"),
                                             ("double_click", "Double target", "Details opened"), ("drag", "Drag source", "Card dropped")] {
                let observed = try await command(worker, "snapshot", tabID: gestureID)
                let items = observed["elements"] as! [[String: Any]]
                let source = items.first { $0["text"] as? String == label }!["i"] as! Int
                var args: [String: Any] = ["gesture": kind, "index": source]
                if kind == "drag" { args["toIndex"] = items.first { $0["text"] as? String == "Drop target" }!["i"] as! Int }
                let delivered = try await command(worker, "cdpGesture", tabID: gestureID, args: args)
                try check(delivered["verified"] as? Bool == false, "driver delivery never claims goal verification")
                let result = try await command(worker, "read", tabID: gestureID)
                try check((result["text"] as? String ?? "").contains(expected), "real Chromium " + kind + " produces intended page result")
            }
            let staleGesture = try await command(worker, "snapshot", tabID: gestureID)
            _ = try await command(worker, "snapshot", tabID: gestureID)
            do {
                _ = try await worker.command("cdpGesture", tabID: gestureID, args: token(staleGesture, ["gesture": "hover", "index": 0]))
                try check(false, "stale gesture refused")
            } catch { checks += 1 }
            _ = try await command(worker, "closeTab", tabID: gestureID)
            let disposable = try await worker.newTab(page("Disposable"))
            let completedRun = worker.generation
            await worker.runEnded(keep: id, generation: completedRun)
            do { _ = try await command(worker, "tabInfo", tabID: disposable); preconditionFailure("kept unused task tab") } catch { checks += 1 }
            let finalPhoto = try await command(worker, "captureTask", tabID: id)
            try check((finalPhoto["image"] as? String)?.isEmpty == false, "captures retained tab after idle freeze")
            worker.runStarted()
            await worker.runEnded(keep: nil, generation: completedRun)
            let retained = try await command(worker, "tabInfo", tabID: id)
            try check(retained["title"] as? String == "Worker", "stale cleanup leaves the next run's tab alone")
            let endingGeneration = worker.generation
            let ending = Task { await worker.runEnded(keep: id, generation: endingGeneration) }
            try await Task.sleep(for: .milliseconds(5))
            worker.runStarted()
            _ = try await command(worker, "snapshot", tabID: id)
            await ending.value
            let stillOwned = try await command(worker, "tabInfo", tabID: id)
            try check(stillOwned["title"] as? String == "Worker", "new run survives an overlapping final-frame capture")
            let recoveredID = try await recovered.newTab(page("Recovered worker"))
            try rememberPID("worker")
            let recoveredInfo = try await command(recovered, "tabInfo", tabID: recoveredID)
            try check(recoveredInfo["title"] as? String == "Recovered worker", "reclaims orphaned owned process without replaying its old target")
            await worker.stop()
            do { _ = try await command(worker, "fill", tabID: id, args:["index": name!, "text":"must fail"]); preconditionFailure("fell through after disconnect") } catch { checks += 1 }
            try check(NSPasteboard.general.changeCount == clipboard, "host clipboard unchanged")
            try check(!activations.pids.contains(where: { ownedPIDs.contains($0) }), "owned worker never activates foreground (user app switches allowed)")
            await recovered.stop(); await other.stop()
            try? FileManager.default.removeItem(at: root)
            print("PASS: \(checks) headless Chrome isolation checks")
        } catch {
            await worker.stop(); await recovered.stop(); await other.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
