// Production Telegram routing and transport, with app execution and the Bot API isolated.
import AppKit

enum Config {
    static func value(_ key: String) -> String? { key == "TELEGRAM_BOT_TOKEN" ? "test-token" : "42" }
    static func write(_ values: [String: String]) throws {}
}
enum Secrets { static func mask(_ text: String) -> String { text } }
struct ResultCard: Equatable {
    struct Item: Equatable { var title: String; var subtitle: String?; var detail: String? = nil; var link: String? }
    var title = "Result"
    var text: String? = nil
    var items: [Item] = []
    var plain: String { ([title] + [text].compactMap { $0 } + items.map { [$0.title, $0.subtitle, $0.detail, $0.link].compactMap { $0 }.joined(separator: " — ") }).joined(separator: "\n") }
}
enum Background { static func choice(_ text: inout String) -> Bool? { ExecutionMode.choice(&text) } }
@MainActor final class Agent {
    struct Question { var text: String; var sensitive = false }
    struct Step { enum State { case running, ok, failed, info }; var text: String; var state: State = .ok }
    var store: TaskStore!
    var taskRecordID: UUID?
    var imageOutputRequirement: Int?
    var outputFiles: [URL] = []
    var isRunning = false
    var question: Question?
    var steps: [Step] = []
    var narration = ""
    var answer = ""
    var telegramPageURL: String?
    var screenshot: Data?
    var captures = 0
    var reveals = 0
    var continuation: String?
    var targetApp: NSRunningApplication?
    var selectedText: String?
    var copied: String?
    var annotation: String?
    var selectedFiles: [URL] = []
    var submitted: [String] = []
    var modes: [Bool] = []
    var notes: [String] = []
    var answers: [String] = []
    var onFinish: ((String, Bool) -> Void)?
    func submit(_ text: String, background: Bool, taskID: UUID? = nil) {
        taskRecordID = taskID; submitted.append(text); modes.append(background); isRunning = true
    }
    func addContext(_ text: String) { notes.append(text) }
    func answer(_ text: String) { answers.append(text); question = nil }
    func complete(_ text: String = "Finished", ok: Bool = true) {
        answer = text; isRunning = false; store.finish(taskRecordID, ok: ok, answer: text); onFinish?(text, ok)
    }
    func cancel() { complete("Stopped", ok: false) }
    func telegramScreenshot() async -> Data? { captures += 1; return screenshot }
    func revealTelegramTarget() async { reveals += 1 }
    static func writeLog(_ text: String) {}
}
final class TelegramAPI: URLProtocol {
    static let lock = NSLock()
    static var requests: [(String, [String: Any])] = []
    static var rawRequests: [(String, Data)] = []
    static var nextMessage = 100
    static var failPhotos = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let method = request.url!.lastPathComponent
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), result = Data()
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; result.append(contentsOf: bytes.prefix(n)) }
            data = result
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let id = Self.lock.withLock { () -> Int in
            Self.nextMessage += 1
            var recorded = body; recorded["_responseMessageID"] = body["message_id"] as? Int ?? Self.nextMessage
            Self.requests.append((method, recorded)); Self.rawRequests.append((method, data ?? Data()))
            return Self.nextMessage
        }
        let payload: Data; var status = 200
        if method == "getFile" {
            let file = body["file_id"] as! String
            payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["file_path": "files/\(file).jpg", "file_size": 4]])
        } else if request.url!.path.contains("/file/") {
            payload = Data("file".utf8); if method == "broken.jpg" { status = 500 }
        } else if method == "sendPhoto", Self.lock.withLock({ Self.failPhotos }) { payload = Data("{\"ok\":false}".utf8) }
        else { payload = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["message_id": body["message_id"] as? Int ?? id]]) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func bodies(_ method: String) -> [[String: Any]] { lock.withLock { requests.filter { $0.0 == method }.map { $0.1 } } }
    static func texts(_ method: String = "sendMessage") -> [String] { bodies(method).compactMap { $0["text"] as? String } }
    static func option(_ title: String) -> String? {
        bodies("sendMessage").reversed().compactMap { body -> String? in
            guard let markup = body["reply_markup"] as? [String: Any], let rows = markup["inline_keyboard"] as? [[[String: String]]] else { return nil }
            return rows.flatMap { $0 }.first { $0["text"] == title }?["callback_data"]
        }.first
    }
}
@main struct TelegramTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clinqy-telegram-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TelegramAPI.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        func bridge() -> (Telegram, Agent, TaskStore) {
            let store = TaskStore(file: root.appendingPathComponent(UUID().uuidString + ".json"))
            let bot = Telegram(session: session, downloadDirectory: root, store: store)
            let worker = Agent(); worker.store = store; bot.agent = worker
            worker.onFinish = { [weak bot, weak worker] text, ok in if let worker { bot?.finished(answer: text, ok: ok, result: nil, from: worker) } }
            return (bot, worker, store)
        }
        func message(_ text: String = "", extra: [String: Any] = [:], chat: Int = 42) -> [String: Any] {
            ["chat": ["id": chat, "type": "private"], "text": text].merging(extra) { _, new in new }
        }
        func doc(_ id: String, name: String = "report.pdf", size: Int = 4) -> [String: Any] { ["document": ["file_id": id, "file_name": name, "file_size": size]] }
        func tap(_ bot: Telegram, _ data: String, chat: Int = 42) { bot.handleTap(["id": UUID().uuidString, "message": message(extra: ["message_id": 1], chat: chat), "data": data]) }
        func wait(_ check: () -> Bool) async throws {
            for _ in 0..<600 { if check() { return }; try await Task.sleep(for: .milliseconds(10)) }
            fatalError("Timed out waiting for Telegram")
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(100)) }
        func check(_ test: @autoclosure () -> Bool, _ label: String) { precondition(test(), label); print("PASS \(label)") }

        // The user's exact failure: trailing normal mode must override every global background setting.
        for text in ["Apply to this Luma use normal mode clinqy", "normal mode: open Cursor", "use normal mode open Calculator", "foreground: open Arc", "use foreground: open the browser", "use the browser in foreground mode", "open the browser in the foreground", "apply to this, not in the background"] {
            var value = text; check(ExecutionMode.choice(&value) == false, "explicit Normal routing: \(text)")
        }
        for text in ["in the background: open https://example.com", "read the file in background mode"] { var value = text; check(ExecutionMode.choice(&value) == true, "explicit Background routing") }
        for text in ["change the background color", "blur the people in the background", "type \"use normal mode\"", "calculate the normal mode of a distribution"] { var value = text; check(ExecutionMode.choice(&value) == nil, "task content is not execution mode: \(text)") }

        let (mode, modeWorker, _) = bridge()
        mode.handle(message("open Calculator")); try await wait { TelegramAPI.option("Background") != nil }
        check(modeWorker.submitted.isEmpty, "no action before choosing execution mode")
        let oldMode = TelegramAPI.option("Normal · use my Mac")!
        tap(mode, oldMode); try await wait { modeWorker.submitted.count == 1 }
        check(modeWorker.modes == [false], "Normal selection reaches the desktop controller")
        tap(mode, oldMode); try await settle(); check(modeWorker.submitted.count == 1, "mode choice is single-use")
        modeWorker.complete()

        let (explicit, explicitWorker, _) = bridge()
        explicit.handle(message("Apply to https://example.com use normal mode clinqy")); try await wait { explicitWorker.submitted.count == 1 }
        check(explicitWorker.modes == [false], "normal mode in original user example starts foreground directly")
        explicitWorker.complete()

        let (photo, photoWorker, _) = bridge()
        photo.handle(message("foreground: use this image", extra: ["photo": [["file_id": "small", "width": 10, "height": 10], ["file_id": "large", "width": 100, "height": 100]]]))
        try await wait { photoWorker.submitted.count == 1 }
        check(TelegramAPI.bodies("getFile").compactMap { $0["file_id"] as? String } == ["large"], "largest photo downloaded only once")
        check(photoWorker.selectedFiles.count == 1 && photoWorker.submitted[0].contains(photoWorker.selectedFiles[0].path), "attachment exact local path reaches task")
        let photoBytes = try Data(contentsOf: photoWorker.selectedFiles[0])
        check(photoBytes == Data("file".utf8), "actual downloaded bytes preserved")
        photoWorker.complete()

        let (staged, stagedWorker, _) = bridge()
        staged.handle(message(extra: doc("staged", name: "../../invoice.pdf")))
        try await wait { TelegramAPI.texts().contains { $0.contains("What should I do") } }
        check(stagedWorker.submitted.isEmpty, "file without caption waits")
        staged.handle(message("foreground: read this file")); try await wait { stagedWorker.submitted.count == 1 }
        check(stagedWorker.selectedFiles[0].lastPathComponent == "invoice.pdf", "staged attachments retain sanitized filename")
        stagedWorker.complete()

        let (album, albumWorker, _) = bridge()
        album.handle(message("foreground: merge these", extra: doc("album-a").merging(["media_group_id": "group"]) { _, v in v }))
        album.handle(message(extra: doc("album-b").merging(["media_group_id": "group"]) { _, v in v }))
        try await wait { albumWorker.submitted.count == 1 }
        check(albumWorker.selectedFiles.count == 2, "album starts one task with every attachment")
        albumWorker.complete()

        let (bad, badWorker, _) = bridge()
        let filesBefore = TelegramAPI.bodies("getFile").count
        bad.handle(message("foreground: read this", extra: doc("oversized", size: 21 * 1024 * 1024)))
        try await wait { TelegramAPI.texts().contains { $0.contains("exceeds Telegram") } }
        check(badWorker.submitted.isEmpty && TelegramAPI.bodies("getFile").count == filesBefore, "oversized attachments never start a task")
        bad.handle(message("foreground: read this", extra: doc("broken")))
        try await wait { TelegramAPI.texts().contains { $0.contains("file download failed") } }
        check(badWorker.submitted.isEmpty, "partial attachment failures never execute captions")
        bad.handle(message("foreground: read this", extra: doc("stranger"), chat: 99)); try await settle()
        check(!TelegramAPI.bodies("getFile").contains { $0["file_id"] as? String == "stranger" }, "unpaired chats cannot access app")

        let (conversation, worker, store) = bridge()
        conversation.handle(message("foreground: fill the sample form")); try await wait { worker.submitted.count == 1 }
        worker.narration = "Filling contact details"; store.update(worker.taskRecordID, completedSteps: 2)
        worker.question = .init(text: "Which location?"); store.update(worker.taskRecordID, state: .waiting)
        conversation.ask("Which location?", options: ["Delhi", "Mumbai"], sensitive: false, from: worker)
        try await wait { TelegramAPI.option("Delhi") != nil }
        let oldQuestion = TelegramAPI.option("Delhi")!
        let oldQuestionMessage = TelegramAPI.bodies("sendMessage").last { ($0["text"] as? String)?.contains("Which location?") == true }!["_responseMessageID"] as! Int
        conversation.handle(message("how far along?")); try await wait { TelegramAPI.texts().contains { $0.contains("2 steps completed") && $0.contains("Waiting for your answer") } }
        check(worker.answers.isEmpty && worker.notes.isEmpty, "status commands cannot answer a question")
        conversation.handle(message("How can I do it?")); try await wait { TelegramAPI.texts().contains { $0.contains("Still paused") } }
        check(worker.answers.isEmpty && worker.question != nil, "help request keeps handoff paused")
        tap(conversation, TelegramAPI.option("Open task on Mac")!); try await wait { worker.reveals == 1 }
        check(worker.answers.isEmpty, "Open task reveals only the task without answering")
        tap(conversation, oldQuestion); check(worker.answers == ["Delhi"], "question option answers exact worker")
        worker.question = .init(text: "Which role?")
        conversation.ask("Which role?", options: ["Engineer"], sensitive: false, from: worker)
        tap(conversation, oldQuestion); tap(conversation, oldQuestion, chat: 99)
        conversation.handle(message("Mumbai", extra: ["reply_to_message": ["message_id": oldQuestionMessage]]))
        try await wait { TelegramAPI.texts().contains { $0.contains("That question has ended") } }
        check(worker.answers == ["Delhi"], "stale and unpaired callbacks cannot answer a later question")
        worker.screenshot = Data("test-image".utf8)
        conversation.handle(message("/screenshot")); try await wait { TelegramAPI.bodies("sendPhoto").count == 1 }
        check(worker.captures == 1 && worker.answers.count == 1, "screenshot targets requested worker and preserves pending question")
        worker.question = .init(text: "Secret internal password prompt", sensitive: true)
        conversation.ask(worker.question!.text, options: [], sensitive: true, from: worker)
        conversation.handle(message("/screenshot")); conversation.handle(message("/status")); conversation.handle(message("secret answer"))
        try await wait { TelegramAPI.texts().contains { $0.contains("screenshots are paused") } }
        check(worker.captures == 1 && worker.answers.count == 1 && !TelegramAPI.texts().contains { $0.contains("Secret internal password prompt") }, "private questions block remote answers and screenshots")
        worker.question = nil
        let review = ResultCard(title: "Form review", text: "Check the actual answers", items: (0..<25).map { .init(title: "Field \($0)", subtitle: String(repeating: "value ", count: 60), detail: "detail \($0)", link: nil) })
        let beforePresent = TelegramAPI.texts().count
        conversation.present(review, from: worker); try await settle()
        check(TelegramAPI.texts().count == beforePresent, "intermediate output does not create unsolicited review spam")
        worker.question = .init(text: "Please review these answers. Submit or edit?")
        conversation.ask(worker.question!.text, options: ["Submit", "Edit"], sensitive: false, from: worker)
        try await wait { TelegramAPI.texts().contains { $0.contains("Field 24") } }
        check(TelegramAPI.texts().contains { $0.contains("detail 24") }, "submission review preserves all fields across chunks")
        let unicode = String(repeating: "👩🏽‍💻", count: 1000), chunks = Telegram.chunks(String(repeating: "👩🏽‍💻", count: 1000))
        check(chunks.joined() == unicode && chunks.allSatisfy { $0.utf16.count <= 3800 }, "message chunking preserves Unicode and Telegram limits")
        worker.question = nil
        let beforeFinish = TelegramAPI.texts().count, photosBefore = TelegramAPI.bodies("sendPhoto").count
        worker.complete("Filled, not submitted")
        conversation.finished(answer: "Filled, not submitted", ok: true, result: review, from: worker)
        try await wait { TelegramAPI.texts("editMessageText").contains { $0.contains("✅ Done") && $0.contains("Filled, not submitted") } }
        check(TelegramAPI.texts().count == beforeFinish && TelegramAPI.bodies("sendPhoto").count == photosBefore, "completion edits one status card without duplicate text or automatic photos")
        conversation.handle(message("/result")); try await wait { TelegramAPI.texts().dropFirst(beforeFinish).contains { $0.contains("Field 24") } }
        check(TelegramAPI.texts().dropFirst(beforeFinish).contains { $0.contains("Filled, not submitted") }, "on-demand full result includes status and all answers")

        // Concurrent sessions: browser jobs do not occupy desktop and do not share questions/results.
        let (parallel, desktop, parallelStore) = bridge()
        var browsers: [Agent] = []
        parallel.submitBrowserTask = { [weak parallel] request, files, id in
            guard let parallel else { return false }
            let browser = Agent(); browser.store = parallelStore; browser.selectedFiles = files
            guard parallelStore.start(id) else { return false }
            browsers.append(browser); parallel.attach(browser, taskID: id)
            browser.onFinish = { [weak parallel, weak browser] text, ok in if let browser { parallel?.finished(answer: text, ok: ok, result: nil, from: browser) } }
            browser.submit(request, background: true, taskID: id); return true
        }
        parallel.handle(message("background: read https://example.com/first")); try await wait { browsers.count == 1 }
        parallel.handle(message("background: read https://example.com/second")); try await wait { browsers.count == 2 }
        parallel.handle(message("foreground: open Calculator")); try await wait { desktop.submitted.count == 1 }
        check(browsers.allSatisfy(\.isRunning) && desktop.isRunning && desktop.notes.isEmpty, "two browser tasks and one desktop task stay independent")
        parallel.handle(message("foreground: open TextEdit")); try await wait { parallelStore.queued.count == 1 }
        check(desktop.notes.isEmpty && desktop.submitted.count == 1, "new desktop task queues rather than steering current task")
        desktop.complete("Calculator is open"); try await wait { desktop.submitted.count == 2 }
        check(desktop.submitted[1].contains("TextEdit"), "desktop queue starts when its own controller is free")
        for (index, browser) in browsers.enumerated() {
            browser.question = .init(text: "Question \(index)")
            parallel.ask("Question \(index)", options: ["Answer \(index)"], sensitive: false, from: browser)
        }
        try await wait { TelegramAPI.option("Answer 1") != nil }
        parallel.handle(message("yes")); try await wait { TelegramAPI.texts().contains { $0.contains("More than one task") } }
        check(browsers.allSatisfy { $0.answers.isEmpty }, "ambiguous plain answer cannot reach a random parallel task")
        tap(parallel, TelegramAPI.option("Answer 0")!); check(browsers[0].answers == ["Answer 0"] && browsers[1].answers.isEmpty, "parallel question buttons are task-scoped")
        // A second URL while a question waits is another request, never its answer.
        parallel.handle(message("background: read https://example.com/third")); try await wait { browsers.count == 3 }
        check(browsers[1].answers.isEmpty && browsers[1].notes.isEmpty, "new URL during a question becomes an independent task")
        let stoppedID = browsers[1].taskRecordID!.uuidString.prefix(8)
        parallel.handle(message("/stop \(stoppedID)")); try await wait { !browsers[1].isRunning }
        check(browsers[0].isRunning && browsers[2].isRunning && desktop.isRunning, "stop cancels only its Telegram task")
        let captureCount = desktop.captures
        parallel.handle(message("/screenshot \(String(store.records.first!.id.uuidString.prefix(8)))")); try await settle()
        check(desktop.captures == captureCount, "foreign task IDs cannot capture another controller")
        parallel.handle(message("/stop all")); try await wait { !desktop.isRunning && browsers.allSatisfy { !$0.isRunning } }
        let (foreign, macWorker, _) = bridge(); macWorker.isRunning = true
        foreign.handle(message("/stop")); try await settle(); check(macWorker.isRunning, "Telegram stop never cancels unrelated Mac work")

        // Repeated Telegram delivery, restart review, and no accidental foreground slot reservation.
        let (repeatBot, repeatWorker, _) = bridge()
        let repeated = message("foreground: open Calculator", extra: ["message_id": 777])
        repeatBot.handle(repeated); try await wait { repeatWorker.submitted.count == 1 }
        repeatWorker.complete("Calculator opened")
        repeatBot.handle(repeated); try await settle()
        check(repeatWorker.submitted.count == 1, "duplicate Telegram delivery cannot execute the task twice")

        let (restoredBot, restoredWorker, restoredStore) = bridge()
        let saved = restoredStore.enqueue("open Calculator", source: .telegram, background: false, conversationID: 42)!
        restoredWorker.isRunning = true
        restoredBot.startQueued(saved, reviewed: true)
        check(restoredWorker.submitted.isEmpty && restoredStore.record(saved)?.state == .queued, "reviewed queued request never reserves a busy desktop slot")
        restoredWorker.isRunning = false
        restoredBot.finished(answer: "Other task done", ok: true, result: nil, from: restoredWorker)
        try await wait { restoredWorker.submitted.count == 1 }
        check(restoredWorker.taskRecordID == saved && restoredWorker.modes == [false], "queued request retains its saved mode and task ID")
        restoredWorker.complete()
        let privateTask = restoredStore.enqueue("test-secret", source: .telegram, background: false, conversationID: 42)!
        // The production TaskStore tests exercise redaction; this suite checks review without slot admission.
        check(restoredStore.reviewQueued(privateTask) && restoredStore.record(privateTask)?.state == .queued, "review-only transition does not start work")
        restoredStore.cancelQueued(privateTask)

        let (questionQueue, questionWorker, questionStore) = bridge()
        questionQueue.handle(message("foreground: read the sample form")); try await wait { questionWorker.submitted.count == 1 }
        questionWorker.question = .init(text: "Choose a location")
        questionQueue.ask("Choose a location", options: ["Delhi"], sensitive: false, from: questionWorker)
        questionQueue.handle(message("foreground: open TextEdit")); try await wait { questionStore.queued.count == 1 }
        check(questionWorker.answers.isEmpty && questionWorker.question != nil, "explicit second task cannot answer a pending question")
        questionQueue.handle(message("/stop all")); try await settle()
        check(questionStore.queued.isEmpty && questionWorker.submitted.count == 1, "stop all clears queued Telegram work before handoff")

        let (dedup, dedupWorker, _) = bridge()
        dedup.handle(message("foreground: report a short result")); try await wait { dedupWorker.submitted.count == 1 }
        let doneText = "A unique verified completion answer"
        dedup.present(ResultCard(title: "A short result", text: doneText), from: dedupWorker)
        dedupWorker.complete(doneText)
        try await settle()
        let resultBefore = TelegramAPI.texts().count
        dedup.handle(message("/result"))
        try await wait { TelegramAPI.texts().count > resultBefore }
        let resultText = TelegramAPI.texts().last!
        check(resultText.components(separatedBy: doneText).count == 2, "auto-generated result text appears only once on completion and result replay")
        let (noModeTask, noModeWorker, noModeStore) = bridge()
        noModeTask.handle(message("normal mode")); try await settle()
        check(noModeWorker.submitted.isEmpty && noModeStore.records.isEmpty, "mode-only message cannot create an empty task")

        let (savedBot, savedWorker, savedStore) = bridge()
        let finishedID = savedStore.enqueue("Read a saved result", source: .telegram, background: false, conversationID: 42)!
        check(savedStore.start(finishedID), "saved-result fixture starts")
        savedStore.finish(finishedID, ok: true, answer: "Verified saved outcome")
        let savedBefore = TelegramAPI.texts().count
        savedBot.handle(message("/task \(finishedID.uuidString.prefix(8))"))
        savedBot.handle(message("/result"))
        try await wait { TelegramAPI.texts().dropFirst(savedBefore).filter { $0.contains("Verified saved outcome") }.count == 2 }
        check(TelegramAPI.texts().last!.contains("Succeeded") && TelegramAPI.texts().last!.contains("Normal") && savedWorker.submitted.isEmpty, "selected results survive app restart without a live worker")

        let (missingBot, missingWorker, missingStore) = bridge()
        missingWorker.isRunning = true
        let missing = missingStore.enqueue("read missing attachment", files: [root.appendingPathComponent("no-such-file.pdf")], source: .telegram, background: false, conversationID: 42)!
        missingBot.startQueued(missing, reviewed: true)
        let afterMissing = missingStore.enqueue("open Calculator after missing file", source: .telegram, background: false, conversationID: 42)!
        missingBot.startQueued(afterMissing, reviewed: true)
        missingWorker.isRunning = false
        missingBot.finished(answer: "Mac work complete", ok: true, result: nil, from: missingWorker)
        try await wait { missingWorker.submitted.count == 1 }
        check(missingStore.record(missing)?.state == .failed && missingWorker.taskRecordID == afterMissing, "missing attachment fails cleanly and does not strand the following task")
        missingWorker.complete()

        let (cancelled, cancelledWorker, _) = bridge()
        cancelled.handle(message("foreground: merge", extra: doc("cancel-album").merging(["media_group_id": "cancel"]) { _, v in v }))
        cancelled.handle(message("/stop")); try await Task.sleep(for: .milliseconds(1000))
        check(cancelledWorker.submitted.isEmpty && !TelegramAPI.bodies("getFile").contains { $0["file_id"] as? String == "cancel-album" }, "stop cancels in-flight album ingestion")
        check(Telegram.formKey(url: "a", answers: [("City", "Delhi")]) != Telegram.formKey(url: "a", answers: [("City", "Pune")]), "changed answers invalidate form approval")
        check(Telegram.formKey(url: "a", answers: []) != Telegram.formKey(url: "b", answers: []), "form approval cannot cross pages")
        check(Telegram.intent("Can you send me an image of what you're doing right now?") == .screenshot && Telegram.intent("set the status to available") == nil, "conversational controls do not hijack ordinary task text")
        // A grouped image request has one status card and three requested photos, not four completion messages.
        let (media, coordinator, mediaStore) = bridge()
        media.handle(message("foreground: open 3 tabs and send the first image from each"))
        try await wait { coordinator.submitted.count == 1 }
        let rootID = coordinator.taskRecordID!
        mediaStore.coordinate(rootID)
        var imageWorkers: [Agent] = []
        try await settle()
        let beforeChildren = TelegramAPI.texts().count
        for index in 0..<3 {
            let id = mediaStore.enqueue("Child image goal \(index)", source: .telegram, background: true, conversationID: 42, parentID: rootID)!
            media.registerBrowserTask(id)
            check(mediaStore.start(id), "image child admitted independently")
            let child = Agent(); child.store = mediaStore
            child.onFinish = { [weak media, weak child] text, ok in if let child { media?.finished(answer: text, ok: ok, result: nil, from: child) } }
            media.attach(child, taskID: id); child.submit("Child image goal \(index)", background: true, taskID: id)
            imageWorkers.append(child)
        }
        try await settle()
        check(TelegramAPI.texts().count == beforeChildren, "parallel children never create separate status or completion cards")
        check(imageWorkers.allSatisfy { $0.imageOutputRequirement == 1 }, "parent image delivery requirement is preserved in every child")
        let photosStart = TelegramAPI.bodies("sendPhoto").count
        for (index, child) in imageWorkers.enumerated() {
            let asset = ImageAsset(jpeg: Data("actual-image-\(index)".utf8), source: "https://example.com/\(index).jpg", title: "Image \(index)")
            let delivered = await media.deliverImage(asset, caption: asset.title, from: child)
            check(delivered, "actual image output requires an acknowledged Bot API upload")
            let duplicate = await media.deliverImage(asset, caption: asset.title, from: child)
            check(duplicate, "acknowledged image retry is deduplicated")
            let extra = ImageAsset(jpeg: Data("extra-\(index)".utf8), source: "https://example.com/extra-\(index).jpg", title: "Extra")
            let extraSent = await media.deliverImage(extra, caption: "Not requested", from: child)
            check(!extraSent, "requested photo count prevents extra unsolicited output")
            child.complete("Image \(index) delivered")
        }
        coordinator.complete("All child media returned")
        try await settle()
        check(TelegramAPI.bodies("sendPhoto").count == photosStart + 3 && TelegramAPI.texts().count == beforeChildren, "three requested images, one parent completion, zero child completion spam")
        check(TelegramAPI.texts("editMessageText").contains { $0.contains("3/3 requested images delivered") && $0.contains("✅ Done") }, "group completion reports acknowledged image counts")
        imageWorkers[0].screenshot = Data("group-task-view".utf8)
        imageWorkers[1].screenshot = Data("group-task-view".utf8)
        imageWorkers[2].screenshot = Data("group-task-view".utf8)
        let screenshotCount = TelegramAPI.bodies("sendPhoto").count
        media.handle(message("/screenshot"))
        try await wait { TelegramAPI.bodies("sendPhoto").count == screenshotCount + 1 }
        check(coordinator.captures == 0 && imageWorkers.reduce(0, { $0 + $1.captures }) == 1, "group screenshot targets a real child tab rather than an empty coordinator")
        let recordCount = mediaStore.records.count
        media.handle(message("What is the progress ?")); try await settle()
        check(mediaStore.records.count == recordCount && TelegramAPI.texts().last!.contains("3/3 requested images delivered"), "natural progress reports parent group without starting another task")
        media.handle(message("/runs")); try await settle()
        check(!imageWorkers.contains { TelegramAPI.texts().last!.contains("[" + String($0.taskRecordID!.uuidString.prefix(8)).lowercased() + "]") }, "runs lists parent tasks rather than internal child jobs")

        let (failedMedia, failedWorker, failedStore) = bridge()
        failedMedia.handle(message("foreground: send the first image")); try await wait { failedWorker.submitted.count == 1 }
        let failedAsset = ImageAsset(jpeg: Data("photo".utf8), source: "https://example.com/failure.jpg", title: "Failure fixture")
        let failedStart = TelegramAPI.bodies("sendPhoto").count
        TelegramAPI.lock.withLock { TelegramAPI.failPhotos = true }
        let failedDelivery = await failedMedia.deliverImage(failedAsset, caption: "Fixture", from: failedWorker)
        TelegramAPI.lock.withLock { TelegramAPI.failPhotos = false }
        let uncertainRetry = await failedMedia.deliverImage(failedAsset, caption: "Fixture", from: failedWorker)
        check(!failedDelivery && !uncertainRetry && TelegramAPI.bodies("sendPhoto").count == failedStart + 1, "unacknowledged photo delivery fails closed without blind retry")
        failedWorker.complete("I described the image but did not send it")
        try await settle()
        check(failedStore.record(failedWorker.taskRecordID)?.state == .failed, "description without photo delivery cannot become Succeeded")
        check(TelegramAPI.texts("editMessageText").contains { $0.contains("Image delivery incomplete: 0/1") && $0.contains("⚠️ Couldn't finish") }, "partial media results are labelled honestly")
        let (analysisOnly, analysisWorker, _) = bridge()
        analysisOnly.handle(message("foreground: describe this image")); try await wait { analysisWorker.submitted.count == 1 }
        let unsolicited = await analysisOnly.deliverImage(failedAsset, caption: "Not requested", from: analysisWorker)
        check(!unsolicited, "image analysis does not authorize unsolicited photo output")
        analysisWorker.complete()
        let (outputs, outputWorker, outputStore) = bridge()
        let ownFile = root.appendingPathComponent("created-screenshot.png")
        try Data("fixture".utf8).write(to: ownFile)
        outputs.handle(message("foreground: capture a local screenshot without sending it"))
        try await wait { outputWorker.submitted.count == 1 }
        outputWorker.outputFiles = [ownFile]
        outputStore.setOutputs(outputWorker.taskRecordID, files: [ownFile])
        outputWorker.complete("Screenshot saved locally")
        check(outputStore.record(outputWorker.taskRecordID)?.outputs == [ownFile.path], "created screenshot path is persisted with its exact task")
        let offerBefore = TelegramAPI.texts().count
        outputs.handle(message("send it on WhatsApp to my own chat"))
        try await wait { TelegramAPI.texts().count > offerBefore }
        tap(outputs, TelegramAPI.option("Normal · use my Mac")!)
        try await wait { outputWorker.submitted.count == 2 }
        check(outputWorker.selectedFiles == [ownFile] && outputWorker.submitted.last!.contains(ownFile.path), "forwarding follow-up inherits the actual generated screenshot")
        outputWorker.complete("Forwarding test stopped", ok: false)
        print("All Telegram attachment, routing, concurrency and conversation tests passed.")
    }
}
