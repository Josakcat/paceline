import Charts
import SwiftUI

/// The drop-down under the menu bar icon: today's total, plan limits left,
/// and the breakdown per model, project and tool.
struct UsagePanelView: View {
    let model: AppModel
    let controller: AppController

    var body: some View {
        let radius = model.appearance.radius(18)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: PacelineMark.template(width: 16)).renderingMode(.template).foregroundStyle(.secondary)
                Text("AI Usage").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { controller.showSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider().overlay(.white.opacity(0.08))
            ScrollView {
                TokensView(model: model, controller: controller).padding(.horizontal, 10).padding(.vertical, 10)
            }
            .scrollIndicators(.never)
        }
        .frame(width: AppController.panelSize.width, height: AppController.panelSize.height)
        .background(GlassSurface(appearance: model.appearance, radius: radius))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }
}

struct TokensView: View {
    let model: AppModel
    let controller: AppController

    /// Installed, but no limits on this Mac: why not.
    private var missingPlans: [(agent: String, why: String)] {
        var missing: [(agent: String, why: String)] = []
        func lacks(_ agent: String) -> Bool {
            model.otherUsage.contains { $0.source == agent } && !model.plans.contains { $0.agent == agent }
                && !model.suggestions.contains { $0.agent == agent }   // signed out says more; the suggestion has it
        }
        if lacks("Codex") { missing.append(("Codex", "Limits come only from the Codex CLI’s sessions; the app doesn’t save them.")) }
        if lacks("Antigravity") {
            missing.append(("Antigravity", model.fetchFresh ? "Limits come from agy (Antigravity’s CLI); install it to see them."
                                                          : "Limits come from agy: turn on Fetch fresh numbers in Settings."))
        }
        return missing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.shownSuggestions.isEmpty || !model.signInDone.isEmpty {
                SuggestionsCard(suggestions: model.shownSuggestions, done: model.signInDone.sorted(), controller: controller)
            }
            // Signing in comes first; the card above says how.
            let setup = model.claudePlan == nil && !model.suggestions.contains(where: { $0.id == "signin|Claude" })
            let missing = missingPlans
            // Only with something under it: a first launch had a bare "PLAN LEFT".
            if !model.plans.isEmpty || setup || !missing.isEmpty {
                if !model.plans.isEmpty {
                    PlanSection(plans: model.orderedPlans)
                    SwitchAccountLine(plans: model.plans, accounts: model.claudeAccounts, controller: controller)
                }
                if setup { ClaudePlanSetup(model: model, controller: controller) }
                ForEach(missing, id: \.agent) { missing in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(missing.agent).font(.system(size: 11.5, weight: .medium))
                        Text(missing.why).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().opacity(0.4).padding(.vertical, 4)
            }
            // Today's total once: the big number in the chosen unit, the other unit below.
            VStack(alignment: .leading, spacing: 3) {
                Button { controller.toggleUnits() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(model.showUSD ? Format.usd(model.spend) : Format.tokens(model.totalTokens))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .contentTransition(.numericText())
                        if !model.showUSD { Text("tokens").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
                .help("Today, all AIs. Click to switch $ / tokens.")
                Text("today · " + (model.showUSD ? "\(Format.tokens(model.totalTokens)) tokens" : Format.usd(model.spend))
                     + " · \(model.totalRequests) requests" + (model.hasUnpriced ? " · some prices unknown" : ""))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            HistoryChart(history: model.history, showUSD: model.showUSD, accounts: model.claudeAccounts, order: model.aiOrder)
            let claude = model.claudeUsage
            let accounts = model.claudeByAccount
            if !accounts.isEmpty {
                Text("BY CLAUDE ACCOUNT").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(accounts, id: \.name) { account in
                    HStack(spacing: 6) {
                        Image(nsImage: AILogos.listIcon(for: account.name, size: 14))
                        Text(account.name).font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                        Text((model.showUSD ? Format.usd(account.usage.totalUSD) : Format.tokens(account.usage.totalTokens) + " tokens")
                             + " · \(account.usage.messages) requests")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
            section("By model", buckets: claude.byModel, unpriced: Set(claude.unpricedModels.map(Pricing.displayName)))
            section("By project", buckets: claude.byProject)
            // Only AIs used today: the rest are in Settings → Accounts.
            ForEach(model.usedToday, id: \.source) { OtherSourceView(usage: $0) }
            Text(model.usedToday.isEmpty
                 ? "API-equivalent list prices, from Claude Code logs in " + (accounts.isEmpty ? "~/.claude/projects." : "each account’s projects folder.")
                 : "API-equivalent list prices, from Claude Code logs and the other tools’ local files. Models without a known price count as $0.")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
        }
        .padding(.horizontal, 2)
    }

    /// `unpriced`: names whose tokens have no known price; they say so instead of "$0.00".
    @ViewBuilder private func section(_ title: String, buckets: [String: UsageBucket], unpriced: Set<String> = []) -> some View {
        Text(title.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6)
        let rows = buckets.sorted { $0.value.usd > $1.value.usd }.prefix(6)
        let maxUSD = max(rows.map(\.value.usd).max() ?? 0, 0.000_001)
        if rows.isEmpty { Text("—").foregroundStyle(.tertiary) }
        ForEach(Array(rows), id: \.key) { name, bucket in
            HStack(spacing: 8) {
                Text(name).font(.system(size: 11.5)).lineLimit(1).frame(width: 92, alignment: .leading)
                GeometryReader { geo in
                    Capsule().fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule().fill(LinearGradient(colors: [Color(hex: 0x5E5CE6), Color(hex: 0x0A84FF)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * bucket.usd / maxUSD)
                        }
                }
                .frame(height: 5)
                Text("\(Format.tokens(bucket.tokens)) · \(unpriced.contains(name) ? "price unknown" : Format.usd(bucket.usd))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The colours of the history's bars: each AI its own, each extra Claude
/// account Claude's a step softer, in list order (the main account full).
/// Softer is toward white on a dark panel and toward black on a light one,
/// so every step stays readable on its background and apart from the next.
enum ChartColors {
    static let lighter = [0.3, 0.5, 0.68], darker = [0.2, 0.36, 0.5]

    /// Step 0 is the colour itself; past the last step they share it.
    static func shade(_ hex: UInt32, step: Int, dark: Bool) -> UInt32 {
        guard step > 0 else { return hex }
        let steps = dark ? lighter : darker
        let t = steps[min(step, steps.count) - 1], target: Double = dark ? 255 : 0
        return [16, 8, 0].reduce(0) { out, shift in
            out | UInt32((Double((hex >> UInt32(shift)) & 0xFF) * (1 - t) + target * t).rounded()) << UInt32(shift)
        }
    }

    /// A key's step: 0, or an extra account's place in the list + 1 (one no
    /// longer listed takes the softest).
    static func step(forKey key: String, accounts: [ClaudeAccount]) -> Int {
        guard key.hasPrefix("Claude:") else { return 0 }
        return (accounts.firstIndex { UsageHistory.key(account: $0.id) == key } ?? lighter.count - 1) + 1
    }

    /// The bars' stacking, bottom first: Claude's accounts (main, then list
    /// order), then the rest by name; or the user's order (Settings → Order).
    /// Colours go by key, so moving an AI never changes its colour.
    static func stackOrder(_ keys: some Sequence<String>, accounts: [ClaudeAccount], order: [String] = []) -> [String] {
        let builtIn = Array(Set(keys)).sorted {
            ($0.hasPrefix("Claude") ? 0 : 1, step(forKey: $0, accounts: accounts), $0)
                < ($1.hasPrefix("Claude") ? 0 : 1, step(forKey: $1, accounts: accounts), $1)
        }
        return AIOrder.sorted(builtIn, saved: order) { $0 }
    }

    /// For an AI with no colour of its own: the default grey reads as
    /// secondary text on the panel, so it gets a clear magenta instead
    /// (3.7:1 on white, 4.6:1 on the dark panel, nothing like Claude's orange).
    static let gray: UInt32 = 0x8E8E93, unbranded: UInt32 = 0xD04ED6

    static func color(forKey key: String, accounts: [ClaudeAccount], dark: Bool) -> UInt32 {
        let own = Providers.named(UsageHistory.agent(forKey: key))?.color ?? gray
        let base = own == gray ? unbranded : own
        return shade(base, step: step(forKey: key, accounts: accounts), dark: dark)
    }

    /// What a key's bar is called (VoiceOver): the account's name, not its id.
    static func name(forKey key: String, accounts: [ClaudeAccount]) -> String {
        guard key.hasPrefix("Claude:") else { return key }
        return accounts.first { UsageHistory.key(account: $0.id) == key }?.name ?? "Removed Claude account"
    }

    /// Relative luminance (WCAG), and the contrast between two colours.
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The heights the bars are drawn at: every segment above 0 at least
/// `minPoints` tall in a plot `plotHeight` points high, so a 1% AI next to
/// a big Claude day still shows. The tallest day keeps its height (the
/// scale's top): its bigger segments give up the room, each by the same
/// share of what it has above the minimum, so their order stays. Only what's
/// drawn changes; totals and VoiceOver read the real values.
enum ChartHeights {
    static func drawn(_ days: [[Double]], plotHeight: Double, minPoints: Double = 2.5) -> [[Double]] {
        let top = days.map { $0.reduce(0) { $0 + max($1, 0) } }.max() ?? 0
        guard top > 0, plotHeight > 0 else { return days }
        let least = top * minPoints / plotHeight
        return days.map { day in
            let raised = day.map { $0 > 0 ? max($0, least) : 0 }
            guard raised.reduce(0, +) > top else { return raised }
            let count = Double(day.filter { $0 > 0 }.count)
            let room = top - least * count
            guard room > 0 else { return day.map { $0 > 0 ? top / count : 0 } }
            let above = day.reduce(0) { $0 + max($1 - least, 0) }
            return day.map { $0 <= 0 ? 0 : $0 < least ? least : least + ($0 - least) * room / above }
        }
    }
}

/// The last 7 days under today's total: a small bar per day, split by AI,
/// in $ or tokens like the total. Only when there's more than today to show.
private struct HistoryChart: View {
    let history: UsageHistory
    let showUSD: Bool
    let accounts: [ClaudeAccount]
    var order: [String] = []
    @Environment(\.colorScheme) private var scheme
    @State private var plotHeight: Double = 30

    private struct Bar: Identifiable {
        let day: Date
        let key: String     // "Claude:work" for an extra account
        let value: Double
        var drawn: Double = 0   // its height in the chart, small ones raised
        var id: String { "\(day.timeIntervalSince1970)-\(key)" }
    }

    var body: some View {
        let days = history.last(7)
        // Every key with tokens or $ gets its colour and a legend entry, stacked in the menu bar's order.
        let keys = UsageHistory.legendKeys(days, accounts: accounts, order: order)
        let perDay = days.map { day, records in
            records.map { Bar(day: day, key: $0.key, value: showUSD ? $0.value.usd : Double($0.value.tokens)) }
                .filter { $0.value > 0 }   // plan lows alone aren't bars
                .sorted { (keys.firstIndex(of: $0.key) ?? 0) < (keys.firstIndex(of: $1.key) ?? 0) }
        }
        let heights = ChartHeights.drawn(perDay.map { $0.map(\.value) }, plotHeight: plotHeight)
        let bars = zip(perDay, heights).flatMap { day, drawn in
            zip(day, drawn).map { bar, height in var bar = bar; bar.drawn = height; return bar }
        }
        let top = max(heights.map { $0.reduce(0, +) }.max() ?? 0, 1e-9)
        let note = UsageHistory.unpricedNote(days, accounts: accounts, order: order, showUSD: showUSD)
        let total = bars.reduce(0) { $0 + $1.value }
        let daysWithData = Set(bars.map(\.day)).count
        if daysWithData > 1 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("LAST 7 DAYS").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Text((showUSD ? Format.usd(total) : Format.tokens(Int(total)) + " tokens") + " · "
                         + (showUSD ? Format.usd(total / Double(daysWithData)) : Format.tokens(Int(total) / daysWithData)) + "/day")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: .day), y: .value(showUSD ? "$" : "Tokens", bar.drawn))
                        .foregroundStyle(by: .value("AI", bar.key))
                        .cornerRadius(2)
                        .accessibilityLabel(bar.day.formatted(.dateTime.weekday(.wide)) + ", " + ChartColors.name(forKey: bar.key, accounts: accounts))
                        .accessibilityValue(showUSD ? Format.usd(bar.value) : Format.tokens(Int(bar.value)) + " tokens")
                }
                .chartForegroundStyleScale(domain: keys, range: keys.map { Color(hex: ChartColors.color(forKey: $0, accounts: accounts, dark: scheme == .dark)) })
                .chartYScale(domain: 0...top)   // the tallest day fills the plot, so the minimum is in real points
                .chartLegend(.hidden)
                .chartYAxis(.hidden)
                .chartOverlay { proxy in
                    Color.clear
                        .onAppear { plotHeight = proxy.plotSize.height }
                        .onChange(of: proxy.plotSize.height) { _, height in plotHeight = height }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow)).font(.system(size: 9))
                    }
                }
                .frame(height: 46)
                .accessibilityLabel("Last 7 days: \(showUSD ? Format.usd(total) : Format.tokens(Int(total)) + " tokens") in all")
                legend(keys, totals: UsageHistory.totals(days, showUSD: showUSD))
                if let note {
                    Text(note).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .help(note)
                }
            }
            .padding(.bottom, 2)
        }
    }
}

extension HistoryChart {
    /// Logo, colour, name and 7-day total per key, wrapping onto the next
    /// line if they don't fit (a name is never cut).
    func legend(_ keys: [String], totals: [String: String]) -> some View {
        FlowLayout(spacing: 8, lineSpacing: 2) {
            ForEach(keys, id: \.self) { key in
                let name = ChartColors.name(forKey: key, accounts: accounts)
                let listed = !key.hasPrefix("Claude:") || accounts.contains { UsageHistory.key(account: $0.id) == key }
                HStack(spacing: 3) {
                    Circle().fill(Color(hex: ChartColors.color(forKey: key, accounts: accounts, dark: scheme == .dark)))
                        .frame(width: 6, height: 6)
                    Image(nsImage: AILogos.listIcon(for: listed ? name : "Claude", size: 11))
                    Text(name).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    if let total = totals[key] {
                        Text(total).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.primary.opacity(0.75))
                            .lineLimit(1).fixedSize()
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Lays its views out left to right, starting a new line when one doesn't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

/// Plan limits left: a block per agent, a bar per window. An agent with several
/// model groups (Antigravity) gets one header and a line per group. Old data is dimmed.
struct PlanSection: View {
    let plans: [PlanUsage]

    private var agents: [(agent: String, plans: [PlanUsage])] {
        var out: [(agent: String, plans: [PlanUsage])] = []
        for plan in plans {
            if let i = out.firstIndex(where: { $0.agent == plan.agent }) { out[i].plans.append(plan) } else { out.append((plan.agent, [plan])) }
        }
        return out
    }

    var body: some View {
        Text("PLAN LEFT").font(.system(size: 10)).foregroundStyle(.secondary)
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                ForEach(agents, id: \.agent) { entry in
                    let newest = entry.plans.max { $0.at < $1.at }
                    let stale = newest?.isStale(now: context.date) ?? false
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(nsImage: AILogos.listIcon(for: entry.agent, size: 14))
                            Text(entry.plans.count == 1 ? entry.plans[0].title : entry.agent).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Spacer()
                            if let age = newest?.age(now: context.date) {
                                Text(age).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            } else if Self.onPace(entry.plans, now: context.date) {
                                Text("On pace").font(.system(size: 10.5)).foregroundStyle(Color(hex: 0x32D74B).opacity(0.8))
                            }
                        }
                        if entry.plans.count == 1 {
                            let labelWidth: CGFloat = entry.plans[0].windows.contains { $0.isModelScoped } ? 62 : 34
                            ForEach(entry.plans[0].windows) { window in
                                WindowBar(window: window, now: context.date, stale: stale, pace: entry.plans[0].pace(window, now: context.date),
                                          labelWidth: labelWidth)
                            }
                        } else {
                            ForEach(entry.plans) { GroupRow(plan: $0, now: context.date, stale: stale) }
                        }
                    }
                    .opacity(stale ? 0.6 : 1)
                }
            }
        }
    }

    /// Nothing on course to run out or already out, and at least one window with enough to tell.
    static func onPace(_ plans: [PlanUsage], now: Date) -> Bool {
        let paces = plans.flatMap { plan in plan.windows.compactMap { plan.pace($0, now: now) } }
        let out = plans.contains { $0.windows.contains { $0.left == 0 } }
        return !out && paces.contains(.onPace) && !paces.contains { $0 != .onPace }
    }
}

/// With several Claude accounts, one low and another with clearly more:
/// "Work has 80% left — switch to it for now", a Copy for the command that
/// opens Claude Code with it, and × to hide it until that window's next round.
private struct SwitchAccountLine: View {
    let plans: [PlanUsage]
    let accounts: [ClaudeAccount]
    let controller: AppController
    @AppStorage("dismissedSwitch", store: Demo.defaults) private var dismissed = ""
    @State private var copied = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let hint = AccountSwitch.hint(plans, accounts: accounts, now: context.date), hint.id != dismissed {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hint.text).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        Text(hint.why).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(copied ? "Copied" : "Copy") {
                        controller.copyString(hint.command)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .controlSize(.small).help(hint.command)
                    Button { dismissed = hint.id } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide until this limit resets").accessibilityLabel("Hide")
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 2)
            }
        }
    }
}

/// "Runs out in 1h 20m · resets in 2h 46m": orange, red within 30 minutes.
private struct RunsOutLine: View {
    let label: String?
    let seconds: TimeInterval
    let resets: String?

    var body: some View {
        Text([label, "Runs out in \(PlanWindow.duration(seconds))", resets].compactMap { $0 }.joined(separator: " · "))
            .font(.system(size: 10.5)).lineLimit(1)
            .foregroundStyle(Color(nsColor: seconds <= 30 * 60 ? .systemRed : .systemOrange))
    }
}

/// One model group on a line: its name, then 5h and Week % left (reset times in the tooltip).
private struct GroupRow: View {
    let plan: PlanUsage
    let now: Date
    let stale: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(plan.group ?? plan.agent).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(["5h", "Week"], id: \.self) { label in
                let window = plan.window(label)
                HStack(spacing: 3) {
                    Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text(window.map { "\($0.left)%" } ?? "–").font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(window.map { WindowBar.tint($0, stale: stale) } ?? .secondary)
                }
                .frame(width: label == "5h" ? 58 : 72, alignment: .trailing)
            }
        }
        .help(plan.windows.map { w in "\(w.label): " + (w.wasReset ? "reset, no new data" : w.resetText(now: now) ?? "\(w.left)% left") }
            .joined(separator: " · "))
        // Only when one will run out: the soonest, on a line of its own.
        let soonest = plan.windows.compactMap { w -> (PlanWindow, TimeInterval)? in
            if case .runsOut(let t)? = plan.pace(w, now: now) { return (w, t) }
            return nil
        }.min { $0.1 < $1.1 }
        if let soonest {
            RunsOutLine(label: soonest.0.label, seconds: soonest.1, resets: soonest.0.resetText(now: now))
        }
    }
}

/// What Paceline can't read yet and how to fix it, in one card. × hides it
/// until something changes.
private struct SuggestionsCard: View {
    let suggestions: [Suggestion]
    var done: [String] = []     // just signed in
    let controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SET UP").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { controller.dismissSuggestions() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Hide until something changes").accessibilityLabel("Dismiss")
            }
            ForEach(suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(nsImage: AILogos.listIcon(for: suggestion.agent, size: 14))
                        Text(suggestion.title).font(.system(size: 11.5, weight: .medium))
                    }
                    Text(suggestion.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    SuggestionButtons(suggestion: suggestion, controller: controller)
                }
            }
            ForEach(done.filter { agent in !suggestions.contains { $0.agent == agent } }, id: \.self) { agent in
                HStack(spacing: 5) {
                    Image(nsImage: AILogos.listIcon(for: agent, size: 14))
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(agent) is signed in").font(.system(size: 11.5, weight: .medium))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A suggestion's buttons, in the panel and in Settings → Accounts.
struct SuggestionButtons: View {
    let suggestion: Suggestion
    let controller: AppController
    /// On a one-line row: no Copy command (it's in the row's ⓘ), and a spinner for the waiting text.
    var compact = false
    @State private var copied = false

    var body: some View {
        let waiting = controller.model.signInWaiting.contains(suggestion.agent)
        HStack(spacing: 6) {
            switch suggestion.action {
            case .signIn(let command):
                Button("Sign in…") { controller.signIn(suggestion) }
                    .buttonStyle(.borderedProminent).tint(PacelineMark.deepMint)
                    .help("Opens Terminal running \(command.display)")
                if waiting { waitingLabel }
                // The way round: type it yourself.
                if !compact {
                    Button(copied ? "Copied" : "Copy command") {
                        controller.copyString(command.display)
                        copied = true
                    }
                    .buttonStyle(.link).font(.system(size: 10.5)).fixedSize().help(command.display)
                }
            case .openApp(let bundleID):
                Button("Open \(suggestion.agent)") { controller.openApp(bundleID, for: suggestion.agent) }
                if waiting { waitingLabel }
            case .links(let links):
                ForEach(links, id: \.url) { link in
                    Button(link.title) { NSWorkspace.shared.open(link.url) }.help(link.url.absoluteString)
                }
            case .addAccount:
                Button("Add…") { controller.addFound(suggestion) }
            }
        }
        .controlSize(.small)
    }

    private var waitingLabel: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            if !compact { Text("Waiting for sign-in…").font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize() }
        }
        .help("Waiting for sign-in…")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for sign-in")
    }
}

/// No Claude limits yet: what to do, right here.
private struct ClaudePlanSetup: View {
    let model: AppModel
    let controller: AppController
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(nsImage: AILogos.icon(for: "Claude", size: 14))
                Text("Claude").font(.system(size: 11.5, weight: .medium))
            }
            // Easiest first: let Paceline ask; the status line is the other way.
            Text(model.fetchFresh ? "Asking Claude Code for its 5-hour and weekly limits…"
                                  : "To see Claude’s 5-hour and weekly limits, let Paceline ask Claude Code (no prompt, nothing billed), or set its status line.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if !model.fetchFresh {
                    Button("Ask Claude Code") { controller.setFetchFresh(true) }
                        .buttonStyle(.borderedProminent).tint(PacelineMark.deepMint)
                }
                Button(copied ? "Copied" : "Copy status line") {
                    controller.copyString(PlanUsageReader.statusLineJSON)
                    copied = true
                }
                Button("Open Settings") { controller.showSettings(.accounts) }
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct WindowBar: View {
    let window: PlanWindow
    let now: Date
    var stale = false
    var pace: PlanWindow.Pace? = nil
    /// Wider when one row is "Fable week", so the bars still line up.
    var labelWidth: CGFloat = 34

    /// Red, orange (the menu bar's rule), else green; grey when old or reset with nothing new.
    static func tint(_ window: PlanWindow, stale: Bool) -> Color {
        if stale || window.wasReset { return .white.opacity(0.5) }
        return Warning.color(left: window.left).map { Color(nsColor: $0) } ?? Color(hex: 0x32D74B)
    }

    var body: some View {
        let tint = Self.tint(window, stale: stale)
        HStack(spacing: 8) {
            Text(window.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint).frame(width: geo.size.width * Double(window.left) / 100)
                    }
            }
            .frame(height: 5)
            Text("\(window.left)%").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
                .frame(width: 34, alignment: .trailing)
            Text(window.wasReset ? "no new data" : window.resetText(now: now) ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading).lineLimit(1)
        }
        if case .runsOut(let seconds)? = pace {
            RunsOutLine(label: nil, seconds: seconds, resets: nil).padding(.leading, labelWidth + 8)
        }
    }
}

/// One other tool (e.g. Antigravity): its total, an accuracy badge, and the top models.
struct OtherSourceView: View {
    let usage: SourceUsage

    var body: some View {
        let total = usage.total
        HStack(spacing: 6) {
            Image(nsImage: AILogos.icon(for: usage.source, size: 14))
            Text(usage.source.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(badge).font(.system(size: 8.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .foregroundStyle(usage.accuracy == .exact ? Color(hex: 0x32D74B) : Color(hex: 0xFFB340))
                .background(.white.opacity(0.07), in: Capsule())
            Spacer()
            Text("\(Format.tokens(total.total)) · \(total.messages) requests")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
        if total.messages == 0 {
            Text("Nothing today").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        ForEach(usage.byModel.sorted { $0.value.total > $1.value.total }.prefix(4), id: \.key) { name, counts in
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                Text("in \(Format.tokens(counts.input)) · out \(Format.tokens(counts.output)) · cache \(Format.tokens(counts.cacheRead + counts.cacheWrite))"
                     + (usage.unpricedModels.contains(name) ? " · price unknown" : ""))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        if let note = usage.note {
            Text(note).font(.system(size: 9.5)).foregroundStyle(Color(hex: 0xFFB340))
        }
    }

    private var badge: String {
        switch usage.accuracy {
        case .exact: "EXACT"
        case .estimated: "≈ ESTIMATE"
        case .activity: "≈ ACTIVITY"
        }
    }
}
