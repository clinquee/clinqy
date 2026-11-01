import AppKit
@preconcurrency import UserNotifications

/// How a background run reaches the user, who isn't watching it: a notification when it's done, and one when it
/// needs them, answerable right there (a button per option, or a typed reply). Tapping either opens Clinqy.
@MainActor
enum Notifier {
    /// The user answered the question from the notification.
    static var onAnswer: (String) -> Void = { _ in }
    /// The user tapped a notification (true: the question one): show them Clinqy, or the work.
    static var onOpen: (_ question: Bool) -> Void = { _ in }

    private static let delegate = Delegate()
    /// Which question is on show and the options it was issued with; responses resolve through it by notification id.
    private static var ledger = NotificationLedger()

    static func start() {
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Every category in use: setting them replaces the whole set, so a question's never drops "Done"'s.
    private static var categories: [String: UNNotificationCategory] = [:]

    /// The run has finished (or given up). The result's first items ride along (prices, places, links), and the
    /// notification can show the work, bring its window over, or open the first link. Several stack as one group.
    static func finished(request: String, answer: String, ok: Bool, result: ResultCard? = nil) {
        let content = UNMutableNotificationContent()
        content.title = ok ? "Done" : answer == "Stopped" ? "Stopped" : "Couldn't finish"
        content.subtitle = String(request.prefix(80))
        let items = (result?.items ?? []).prefix(3).map { "• " + $0.title + ($0.subtitle.map { " — " + $0 } ?? "") }
        content.body = ([String(answer.prefix(items.isEmpty ? 240 : 140))] + items).joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "clinqy.done"
        // The link rides with its own notification, so a later "Done" can't redirect this one's Open button.
        let link = result?.items.lazy.compactMap { $0.link.flatMap(URL.init(string:)) }.first
        if let link { content.userInfo = ["link": link.absoluteString] }
        var actions = [UNNotificationAction(identifier: "show", title: "Show me", options: [.foreground]),
                       UNNotificationAction(identifier: "bring", title: "Bring it here", options: [.foreground])]
        if link != nil { actions.append(UNNotificationAction(identifier: "link", title: "Open link", options: [.foreground])) }
        let category = UNNotificationCategory(identifier: link == nil ? "clinqy.done" : "clinqy.done.link", actions: actions,
                                              intentIdentifiers: [], options: [])
        register(category)
        content.categoryIdentifier = category.identifier
        post("clinqy.done.\(UUID().uuidString)", content)
    }

    private static func register(_ category: UNNotificationCategory) {
        // Only the newest question's buttons are needed.
        if category.identifier.hasPrefix("clinqy.q.") { categories = categories.filter { !$0.key.hasPrefix("clinqy.q.") } }
        categories[category.identifier] = category
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.values))
    }

    /// The run is waiting on the user. A private answer (a password, a code) is never typed into a notification:
    /// that one only opens Clinqy.
    static func ask(_ text: String, options: [String], sensitive: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Clinqy needs you"
        content.body = String(text.prefix(240))
        content.sound = .default
        let previous = ledger.liveID
        let issued = ledger.issue(options: options, sensitive: sensitive)
        var actions = issued.actions.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: []) as UNNotificationAction }
        if !sensitive {
            actions.append(UNTextInputNotificationAction(identifier: "reply", title: options.isEmpty ? "Reply" : "Something else…",
                                                         options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"))
        }
        // A category per question: its buttons are the question's own options.
        let category = UNNotificationCategory(identifier: "clinqy.q.\(UUID().uuidString)", actions: actions, intentIdentifiers: [], options: [])
        register(category)
        content.categoryIdentifier = category.identifier
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: previous.map { [$0] } ?? [])
        post(issued.id, content)
    }

    /// The question was answered (here or in Clinqy): its notification goes.
    static func clearQuestion() {
        let live = ledger.liveID
        ledger.clear()
        guard let live else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [live])
        center.removePendingNotificationRequests(withIdentifiers: [live])
    }

    private static func post(_ id: String, _ content: UNMutableNotificationContent) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                let why = error?.localizedDescription ?? "notifications are off for Clinqy"
                DispatchQueue.main.async { Agent.writeLog("notification not shown: \(why)") }
                return
            }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    fileprivate static func respond(notificationID: String, action: String, typed: String?, link: String?) {
        switch action {
        case "bring":
            AgentScreen.bringHere()
            Task { await Background.showLast() }
        case "link":
            if let link, let url = URL(string: link) { NSWorkspace.shared.open(url) }
        default:
            switch ledger.resolve(notificationID: notificationID, action: action, typed: typed) {
            case .answer(let text): onAnswer(text)
            case .open(let question): onOpen(question)
            case .stale: Agent.writeLog("notification response ignored: its question is no longer open")
            }
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // Clinqy is a menu-bar app, often "in front" while its bar is up: show the banner anyway.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
            done([.banner, .sound])
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler done: @escaping () -> Void) {
            let action = response.actionIdentifier
            let typed = (response as? UNTextInputNotificationResponse)?.userText
            let id = response.notification.request.identifier
            let link = response.notification.request.content.userInfo["link"] as? String
            DispatchQueue.main.async {
                Notifier.respond(notificationID: id, action: action, typed: typed, link: link)
                done()
            }
        }
    }
}
