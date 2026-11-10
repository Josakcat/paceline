import Foundation
import UserNotifications

/// What to tell the user about plan limits, worked out from the plans and what
/// was already said, so it can be tested without notifications.
///
/// A window's round is told apart by its reset time. Sent ids are
/// "<plan id>|<window>|<reset, epoch seconds>|<20, 10, runsout or reset>".
enum PlanAlerts {
    struct Alert: Equatable, Sendable {
        let id: String
        let title: String
        let body: String
    }

    /// The alerts due now, and what's been said once they're posted. Old data says nothing.
    /// `accounts`: the extra Claude accounts; a 20% or 10% alert for a Claude
    /// account then says which one has more left (AccountSwitch), in the same alert.
    static func due(_ plans: [PlanUsage], sent: Set<String>, now: Date = Date(), accounts: [ClaudeAccount] = []) -> (alerts: [Alert], sent: Set<String>) {
        var sent = sent, alerts: [Alert] = []
        for plan in plans where !plan.isStale(now: now) {
            let hint = AccountSwitch.hint(plans, accounts: accounts, now: now, from: plan.agent).map { " " + $0.text + "." } ?? ""
            for window in plan.windows {
                guard let resets = window.resets else { continue }
                let round = "\(plan.id)|\(window.label)|\(Int(resets.timeIntervalSince1970))"
                let name = PlanWindow.spokenName(window.label)
                let body = window.resetText(now: now).map { $0.prefix(1).uppercased() + $0.dropFirst() + "." } ?? ""
                // 20% and 10%, once each a round; straight past both says the lower one.
                let crossed = [20, 10].filter { window.left <= $0 }
                if let lowest = crossed.filter({ !sent.contains("\(round)|\($0)") }).last {
                    alerts.append(Alert(id: "\(round)|\(lowest)", title: "\(plan.title): \(window.left)% of the \(name) limit left",
                                        body: (body + hint).trimmingCharacters(in: .whitespaces)))
                }
                crossed.forEach { sent.insert("\(round)|\($0)") }
                if case .runsOut(let seconds)? = plan.pace(window, now: now), seconds <= 30 * 60, sent.insert("\(round)|runsout").inserted {
                    alerts.append(Alert(id: "\(round)|runsout",
                                        title: "\(plan.title): \(name) limit runs out in \(PlanWindow.duration(seconds))", body: body))
                }
            }
            // A 5-hour round that ran low has reset since: said within the hour,
            // not hours later (Paceline was closed, or the plan was old).
            let lowRounds = Set(sent.compactMap { id -> Int? in
                guard let parts = parts(id), parts.plan == plan.id, parts.window == "5h", ["20", "10"].contains(parts.kind) else { return nil }
                return parts.reset
            })
            for reset in lowRounds.sorted() where Date(timeIntervalSince1970: TimeInterval(reset)) <= now {
                let id = "\(plan.id)|5h|\(reset)|reset"
                if sent.insert(id).inserted, now.timeIntervalSince1970 - TimeInterval(reset) < 3600 {
                    alerts.append(Alert(id: id, title: "\(plan.title): 5-hour limit reset", body: "Back to 100%."))
                }
            }
        }
        // Rounds over a week gone are forgotten.
        sent = sent.filter { id in
            parts(id).map { now.timeIntervalSince1970 - TimeInterval($0.reset) < 8 * 86400 } ?? false
        }
        return (alerts, sent)
    }

    /// "<plan id>|<window>|<reset>|<kind>", read from the right: an account's
    /// name (the plan id) may itself contain "|".
    static func parts(_ id: String) -> (plan: String, window: String, reset: Int, kind: String)? {
        let parts = id.components(separatedBy: "|")
        guard parts.count >= 4, let reset = Int(parts[parts.count - 2]) else { return nil }
        return (parts.dropLast(3).joined(separator: "|"), parts[parts.count - 3], reset, parts[parts.count - 1])
    }
}

/// Posts through Notification Center. Permission is asked only when the
/// setting is turned on.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ alert: PlanAlerts.Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }
}
