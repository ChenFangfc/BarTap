import AppKit
import BarTapCore

/// Model prices: the table bundled with BarTap, or a newer copy of LiteLLM's public list saved in
/// Application Support. A refresh happens at most once a week (at most daily while a model has no
/// price), only while AI usage is on and the setting allows it. Nothing else is downloaded.
final class AIPrices {
    private(set) var table: [String: ModelPrice] = [:]
    private(set) var fetched = ""
    private var memo: [String: ModelPrice?] = [:]
    private var refreshing = false

    static var savedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarTap/ai-prices.json")
    }

    private let bundledURL: URL?

    /// - Parameter bundledURL: the bundled table (tests and the promo exporter pass the repo copy).
    init(bundledURL: URL? = Bundle.main.url(forResource: "ai-prices", withExtension: "json")) {
        self.bundledURL = bundledURL
        load()
    }

    func load() {
        let bundled = bundledURL.flatMap { try? Data(contentsOf: $0) }.flatMap(AIPriceTable.decode)
        let saved = (try? Data(contentsOf: Self.savedURL)).flatMap(AIPriceTable.decode)
        let best = [bundled, saved].compactMap { $0 }.max { $0.fetched < $1.fetched }
        table = best?.models ?? [:]
        fetched = best?.fetched ?? ""
        memo.removeAll()
    }

    func price(_ model: String) -> ModelPrice? {
        if let hit = memo[model] { return hit }
        let p = AIPricing.lookup(model, in: table)
        memo[model] = p
        return p
    }

    func refreshIfNeeded(hasUnpriced: Bool, completion: @escaping () -> Void) {
        let last = UserDefaults.standard.object(forKey: "ai.pricesChecked") as? Date ?? .distantPast
        let age = Date().timeIntervalSince(last)
        guard !refreshing, age > 7 * 86_400 || (hasUnpriced && age > 86_400),
              let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json") else { return }
        refreshing = true
        UserDefaults.standard.set(Date(), forKey: "ai.pricesChecked")
        // Ephemeral: no response cache left on disk.
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: URLRequest(url: url, timeoutInterval: 30)) { [weak self] data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            let today = AIUsageBook.dayKey(Date(), calendar: Calendar(identifier: .gregorian))
            let compact = data.flatMap { (response as? HTTPURLResponse)?.statusCode == 200 ? AIPriceTable.compact(fromLiteLLM: $0, fetched: today) : nil }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                guard let compact, let table = AIPriceTable.decode(compact), table.models.count > 50 else { return }
                try? FileManager.default.createDirectory(at: Self.savedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? compact.write(to: Self.savedURL, options: .atomic)
                self.load()
                completion()
            }
        }.resume()
    }
}

/// The AI usage dropdown: ranges, agents, plan limits, top models and a 30-day graph.
final class AIPanel: StatsPanel {
    private let settings: Settings
    private let prices: AIPrices
    private let graph = GraphView()
    private var bigField: NSTextField?
    private var agentRows: [(AIAgent, NSTextField, NSTextField)] = []
    private var planRows: [(NSTextField, NSTextField)] = []
    private var planTitle: NSTextField?
    private var modelRows: [(NSTextField, NSTextField)] = []
    private let note = NSTextField(wrappingLabelWithString: "")
    /// The promo exporter pins this to the sample data's day.
    var clock: () -> Date = { Date() }

    init(settings: Settings, prices: AIPrices, agents: [AIAgent]) {
        self.settings = settings
        self.prices = prices
        super.init()
        bigField = header(L("AI usage"))
        graph.colors = [.systemPurple]
        graph.fixedMax = nil
        graph.minimumPeak = 1 // dollars
        graph.caption = L("Last 90 days, cost at API prices")
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 48).isActive = true
        stack.addArrangedSubview(graph)

        section(L("Tokens · cost"))
        for r in AIRange.allCases { row(Self.rangeName(r), key: "range.\(r.rawValue)") }

        section(L("By agent"))
        for a in agents {
            let v = row(a.displayName, key: "agent.\(a.rawValue)")
            let name = (v.superview as? NSStackView)?.arrangedSubviews.first as? NSTextField ?? NSTextField()
            agentRows.append((a, name, v))
        }

        planTitle = section(L("Plan limits · used"))
        planRows = dynamicRows(8, prefix: "plan")

        section(L("Top models this month"))
        modelRows = dynamicRows(4, prefix: "model")

        section(L("Today in detail"))
        row(L("Input"), key: "t.input")
        row(L("Output (incl. reasoning)"), key: "t.output")
        row(L("Cache writes"), key: "t.write")
        row(L("Cache reads"), key: "t.read")

        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = Self.width - 28
        stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? note)
        stack.addArrangedSubview(note)
        finishLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    static func rangeName(_ r: AIRange) -> String {
        switch r {
        case .today: return L("Today")
        case .week: return L("This week")
        case .month: return L("This month")
        case .quarter: return L("This quarter")
        case .year: return L("This year")
        }
    }

    /// "$2,186 / $9,000 · 24%" (used), "$6,814 / $9,000 · 76%" (left), or "limit reached".
    static func creditsText(_ s: AISpend, left: Bool) -> String {
        guard let limit = s.limit, let amount = s.amount(left: left), let fraction = s.fraction(left: left) else {
            return AIFormat.money(s.used, currency: s.currency)
        }
        if s.limitReached { return L("limit reached") + " · " + AIFormat.money(limit, currency: s.currency) }
        return AIFormat.money(amount, currency: s.currency) + " / " + AIFormat.money(limit, currency: s.currency)
            + " · \(Int((fraction * 100).rounded()))%"
    }

    /// Dates in the app's language, like the rest of the dropdown.
    private static var locale: Locale { Loc.isChinese ? Locale(identifier: "zh_CN") : Locale.current }
    private static var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }
    private static var dayFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }

    /// "resets 12:01", or "resets Nov 20 09:41" on another day (no "at": rows are narrow).
    private func reset(_ d: Date?) -> String {
        guard let d else { return "" }
        let time = Self.timeFormatter.string(from: d)
        let same = Calendar.current.isDate(d, inSameDayAs: clock())
        return " · " + L("resets %@", same ? time : Self.dayFormatter.string(from: d) + " " + time)
    }

    override func update(_ s: StatsSnapshot, _ o: StatsRenderer.Options) {
        guard let detail = s.aiDetail else { return }
        let cal = Calendar.current, now = clock()
        let chosen = settings.aiAgents
        let agents = Set(AIAgent.allCases.filter { detail.detected.contains($0) && (chosen.isEmpty || chosen.contains($0)) })
        let price: (String) -> ModelPrice? = { [prices] in prices.price($0) }
        func text(_ t: AIUsageBook.Total) -> String {
            t.tokens.total == 0 ? "–" : "\(AIFormat.tokens(t.tokens.total)) · \(AIFormat.cost(t.cost))\(t.unpricedTokens > 0 ? "+" : "")"
        }
        let range = settings.aiRange
        func from(_ r: AIRange) -> String { AIUsageBook.dayKey(r.start(containing: now, calendar: cal), calendar: cal) }

        let main = detail.book.total(from: from(range), agents: agents, prices: price)
        bigField?.stringValue = AIFormat.cost(main.cost)
        for r in AIRange.allCases { set("range.\(r.rawValue)", text(detail.book.total(from: from(r), agents: agents, prices: price))) }
        graph.series = [detail.book.daily(last: 90, now: now, calendar: cal, agents: agents, prices: price).map(\.cost)]

        for (a, name, value) in agentRows {
            let t = detail.book.total(from: from(range), agents: [a], prices: price)
            name.stringValue = a.displayName + (agents.contains(a) ? "" : " " + L("(not counted)"))
            value.stringValue = text(t)
        }
        let left = settings.aiPlanLeft
        planTitle?.stringValue = (left ? L("Plan limits · left") : L("Plan limits · used")).uppercased()
        var plans: [(String, String)] = []
        for a in AIAgent.allCases {
            guard let p = detail.plans[a] else { continue }
            for w in p.current(now: now).sorted(by: { $0.minutes < $1.minutes }) {
                let label = "\(a.planName) \(w.scope.map { $0 + " " } ?? "")\(w.shortName)"
                plans.append((label, "\(Int(w.percent(left: left).rounded()))%" + reset(w.resetsAt)))
            }
            if let s = p.spend {
                plans.append(("\(a.planName) " + L("usage credits"), Self.creditsText(s, left: left)))
            } else if let c = p.credits {
                plans.append(("\(a.planName) " + L("credits"), String(format: "%.2f", c)))
            }
        }
        for (i, (name, value)) in planRows.enumerated() {
            name.stringValue = i < plans.count ? plans[i].0 : (i == 0 ? L("No plan limits reported yet") : "")
            value.stringValue = i < plans.count ? plans[i].1 : ""
        }

        let models = detail.book.models(from: from(.month), agents: agents, prices: price)
        for (i, (name, value)) in modelRows.enumerated() {
            name.stringValue = i < models.count ? models[i].model : ""
            value.stringValue = i < models.count ? text(models[i].total) : ""
        }

        let today = detail.book.total(from: from(.today), agents: agents, prices: price).tokens
        set("t.input", AIFormat.tokens(today.input))
        set("t.output", AIFormat.tokens(today.output))
        set("t.write", AIFormat.tokens(today.cacheWrite + today.cacheWrite1h))
        set("t.read", AIFormat.tokens(today.cacheRead))

        var lines = [L("Costs are what these tokens would cost at API prices (%@), not what a subscription bills.", prices.fetched.isEmpty ? "–" : prices.fetched)]
        if let claude = detail.plans[.claudeCode] {
            // Claude Code refreshes these now and then; say how old they are once it matters.
            let hours = Int(now.timeIntervalSince(claude.updated) / 3600)
            let when = Calendar.current.isDate(claude.updated, inSameDayAs: now)
                ? Self.timeFormatter.string(from: claude.updated) : Self.dayFormatter.string(from: claude.updated) + " " + Self.timeFormatter.string(from: claude.updated)
            lines.append(hours >= 1 ? L("Claude limits as of %@, %d h ago (from Claude Code).", when, hours)
                                    : L("Claude limits as of %@ (from Claude Code).", when))
        }
        if let p = detail.progress { lines.append(L("Reading history… %d%%", Int(p * 100))) }
        if main.unpricedTokens > 0 { lines.append(L("+ means some models have no known price.")) }
        if note.stringValue != lines.joined(separator: "\n") { note.stringValue = lines.joined(separator: "\n") }
    }
}
