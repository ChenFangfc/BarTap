import Foundation

// AI coding-agent usage: tokens and API-equivalent cost per day, agent and model, read from the
// logs the agents keep on this Mac, plus plan limits where an agent reports them. Everything here
// is pure (no files, no network) and unit-tested; the app feeds it lines and rows.

public enum AIAgent: String, CaseIterable, Codable {
    case claudeCode, codex, geminiCLI, openCode, kiloCode, qwenCode, kimiCode

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .geminiCLI: return "Gemini CLI"
        case .openCode: return "OpenCode"
        case .kiloCode: return "Kilo Code"
        case .qwenCode: return "Qwen Code"
        case .kimiCode: return "Kimi Code"
        }
    }

    /// The plan behind the agent, for limit rows ("Claude 5h": the limit is the plan's, shared
    /// with the chat apps, not Claude Code's own).
    public var planName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .geminiCLI: return "Gemini"
        case .openCode: return "OpenCode"
        case .kiloCode: return "Kilo"
        case .qwenCode: return "Qwen"
        case .kimiCode: return "Kimi"
        }
    }

    /// Two letters for the menu bar, where each agent can get its own segment.
    public var tag: String {
        switch self {
        case .claudeCode: return "CC"
        case .codex: return "CX"
        case .geminiCLI: return "GM"
        case .openCode: return "OC"
        case .kiloCode: return "KL"
        case .qwenCode: return "QW"
        case .kimiCode: return "KM"
        }
    }
}

/// Tokens of one request or of a sum. Input is uncached input only; cache reads and writes are
/// separate because they are priced differently. Output includes reasoning/thinking tokens;
/// `reasoning` repeats that part for display.
public struct TokenCounts: Equatable, Codable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    /// Cache writes at the standard (5-minute) rate.
    public var cacheWrite: Int64 = 0
    /// Claude's 1-hour cache writes, priced higher.
    public var cacheWrite1h: Int64 = 0
    public var reasoning: Int64 = 0

    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, cacheWrite1h: Int64 = 0, reasoning: Int64 = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.reasoning = reasoning
    }

    /// Everything the model processed, the way ccusage counts it (cache included).
    public var total: Int64 { input + output + cacheRead + cacheWrite + cacheWrite1h }
    public var isZero: Bool { total == 0 && reasoning == 0 }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                    reasoning: a.reasoning + b.reasoning)
    }

    public static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }

    /// Field-wise difference, never below zero (a repeated log line whose counts grew).
    public func minus(_ b: TokenCounts) -> TokenCounts {
        TokenCounts(input: max(0, input - b.input), output: max(0, output - b.output), cacheRead: max(0, cacheRead - b.cacheRead),
                    cacheWrite: max(0, cacheWrite - b.cacheWrite), cacheWrite1h: max(0, cacheWrite1h - b.cacheWrite1h),
                    reasoning: max(0, reasoning - b.reasoning))
    }
}

/// One request (or one turn) from an agent's log.
public struct AIUsageEntry: Equatable {
    public var agent: AIAgent
    public var model: String
    public var date: Date
    public var tokens: TokenCounts
    /// Cost the agent itself recorded, when it does (OpenCode).
    public var recordedCost: Double?
    /// Identity across files, for agents that copy history into new files (Claude Code resumes).
    public var dedupeKey: String?
    /// Prompt size class in thousands of tokens: 0, or above 100, 200 or 272. Some models bill
    /// a whole request at a higher rate above their threshold (Haiku 5.5 at 100k, GPT-5 at 272k).
    public var tier: Int
    /// Claude fast mode, billed at a multiple of the standard price.
    public var fast: Bool

    public init(agent: AIAgent, model: String, date: Date, tokens: TokenCounts, recordedCost: Double? = nil,
                dedupeKey: String? = nil, promptTokens: Int64 = 0, fast: Bool = false) {
        self.agent = agent
        self.model = model
        self.date = date
        self.tokens = tokens
        self.recordedCost = recordedCost
        self.dedupeKey = dedupeKey
        self.tier = Self.tier(promptTokens)
        self.fast = fast
    }

    public static func tier(_ prompt: Int64) -> Int {
        prompt > 272_000 ? 272 : prompt > 200_000 ? 200 : prompt > 100_000 ? 100 : 0
    }

    public var longContext: Bool { tier >= 200 }
}

// MARK: - Plan limits

/// One usage window of a subscription, such as "5 hours" or "7 days".
public struct AIPlanWindow: Equatable, Codable {
    public var minutes: Int
    public var usedPercent: Double
    public var resetsAt: Date?
    /// A narrower limit inside the plan, e.g. Claude's weekly Opus limit.
    public var scope: String?

    public init(minutes: Int, usedPercent: Double, resetsAt: Date?, scope: String? = nil) {
        self.minutes = minutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.scope = scope
    }

    /// What the menu bar shows: the share used, or what is left of the limit.
    public func percent(left: Bool) -> Double {
        left ? max(0, 100 - usedPercent) : usedPercent
    }

    /// "5h", "7d"… for compact labels.
    public var shortName: String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
}

/// Usage credits ("extra usage" on Claude plans): billed at API prices once the plan's own limits
/// run out, up to a monthly limit.
public struct AISpend: Equatable, Codable {
    public var used: Double
    public var limit: Double?
    public var currency: String
    public var limitReached: Bool

    public init(used: Double, limit: Double?, currency: String, limitReached: Bool = false) {
        self.used = used
        self.limit = limit
        self.currency = currency
        self.limitReached = limitReached
    }

    /// The amount used, or what is left of the limit.
    public func amount(left: Bool) -> Double? { left ? limit.map { max(0, $0 - used) } : used }

    /// 0…1 of the limit, used or left; nil without a limit.
    public func fraction(left: Bool) -> Double? {
        guard let limit, limit > 0 else { return nil }
        let used = min(max(self.used / limit, 0), 1)
        return left ? 1 - used : used
    }
}

public struct AIPlanStatus: Equatable, Codable {
    public var agent: AIAgent
    public var plan: String?
    public var windows: [AIPlanWindow]
    /// Remaining prepaid credits, when the agent reports them.
    public var credits: Double?
    public var updated: Date
    /// Usage credits spent this month, when the plan has them turned on.
    public var spend: AISpend?

    public init(agent: AIAgent, plan: String?, windows: [AIPlanWindow], credits: Double?, updated: Date, spend: AISpend? = nil) {
        self.agent = agent
        self.plan = plan
        self.windows = windows
        self.credits = credits
        self.updated = updated
        self.spend = spend
    }

    /// Windows whose numbers still mean something: not reset yet and, when the reset time is
    /// unknown, read less than one window ago (a 5-hour figure from this morning says nothing now).
    public func current(now: Date) -> [AIPlanWindow] {
        windows.filter { ($0.resetsAt ?? updated.addingTimeInterval(Double($0.minutes) * 60)) > now }
    }

    /// The window closest to its limit (what a single menu bar number should show).
    public func tightest(now: Date) -> AIPlanWindow? {
        current(now: now).max { $0.usedPercent < $1.usedPercent }
    }
}

// MARK: - Parsers

private func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

private let isoFull: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

public func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return fastISODate(s) ?? isoFull.date(from: s) ?? isoPlain.date(from: s)
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
}

/// "2026-11-01T10:15:30.123Z" or "+08:00" offsets, without a formatter (hundreds of thousands
/// of log lines). nil for anything else; the formatters take over.
func fastISODate(_ s: String) -> Date? {
    let b = Array(s.utf8)
    guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54 || b[10] == 0x20, b[13] == 0x3A, b[16] == 0x3A else { return nil }
    func num(_ from: Int, _ len: Int) -> Int? {
        var v = 0
        for i in from..<(from + len) {
            let c = b[i]
            guard c >= 0x30, c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }
    guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2),
          (1...12).contains(mo), (1...31).contains(d) else { return nil }
    var i = 19, fraction = 0.0
    if i < b.count, b[i] == 0x2E {
        i += 1
        var scale = 0.1
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { fraction += Double(b[i] - 0x30) * scale; scale /= 10; i += 1 }
    }
    var offset = 0
    if i < b.count {
        switch b[i] {
        case 0x5A: offset = 0
        case 0x2B, 0x2D:
            guard i + 5 < b.count + 0, let oh = num(i + 1, 2), let om = num(b[i + 3] == 0x3A ? i + 4 : i + 3, 2) else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2B ? 1 : -1)
        default: return nil
        }
    } else { return nil }
    let seconds = Double(daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se - offset) + fraction
    return Date(timeIntervalSince1970: seconds)
}

/// Pulls single fields out of a JSON line without parsing all of it (lines can be megabytes of
/// message text). A key pattern such as `"requestId":"` can only match a real key: inside JSON
/// strings every quote is escaped. Works on raw bytes with memmem; nothing is copied but the
/// small values returned.
public enum JSONScan {
    public static func find(_ pattern: [UInt8], in buf: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
        guard let base = buf.baseAddress, from >= 0, from < buf.count, pattern.count <= buf.count - from else { return nil }
        return pattern.withUnsafeBytes { p -> Int? in
            guard let hit = memmem(base + from, buf.count - from, p.baseAddress, pattern.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    public static func findLast(_ pattern: [UInt8], in buf: UnsafeRawBufferPointer, from: Int = 0) -> Int? {
        var last: Int?, i = from
        while let hit = find(pattern, in: buf, from: i) { last = hit; i = hit + 1 }
        return last
    }

    /// The string value after `"key":"` (its first or last occurrence), from `from`.
    public static func string(_ pattern: [UInt8], in buf: UnsafeRawBufferPointer, from: Int = 0, last: Bool = false) -> String? {
        guard let at = last ? findLast(pattern, in: buf, from: from) : find(pattern, in: buf, from: from) else { return nil }
        var i = at + pattern.count
        let begin = i
        while i < buf.count {
            let b = buf[i]
            if b == 0x5C { return nil }        // escapes: let the full parser handle it
            if b == 0x22 { return String(decoding: UnsafeRawBufferPointer(rebasing: buf[begin..<i]), as: UTF8.self) }
            i += 1
        }
        return nil
    }

    /// The JSON object after `"key":{` (its first or last occurrence), as its own bytes.
    public static func object(_ pattern: [UInt8], in buf: UnsafeRawBufferPointer, last: Bool = false) -> Data? {
        guard let at = last ? findLast(pattern, in: buf) : find(pattern, in: buf) else { return nil }
        let open = at + pattern.count - 1
        var depth = 0, inString = false, escaped = false, i = open
        while i < buf.count {
            let b = buf[i]
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
            } else if b == 0x22 { inString = true
            } else if b == 0x7B { depth += 1
            } else if b == 0x7D {
                depth -= 1
                if depth == 0 { return Data(UnsafeRawBufferPointer(rebasing: buf[open...i])) }
            }
            i += 1
        }
        return nil
    }

    public static func key(_ name: String) -> [UInt8] { Array("\"\(name)\":\"".utf8) }
    public static func objectKey(_ name: String) -> [UInt8] { Array("\"\(name)\":{".utf8) }
}

/// Claude Code: ~/.claude/projects/<project>/<session>.jsonl, one JSON object per line. Assistant
/// lines carry `message.usage`; resumed sessions copy earlier lines into a new file, so entries are
/// identified by message id + request id.
public enum ClaudeCodeLog {
    private static let usageWord = Array("\"usage\"".utf8), assistantWord = Array("\"assistant\"".utf8)
    private static let messageKey = JSONScan.objectKey("message"), usageKey = JSONScan.objectKey("usage")
    private static let modelKey = JSONScan.key("model"), idKey = JSONScan.key("id"), requestKey = JSONScan.key("requestId")
    private static let timestampKey = JSONScan.key("timestamp"), assistantType = Array("\"type\":\"assistant\"".utf8)
    private static let wireKey = Array("\"wireToolInputs\":".utf8)

    /// The line's own `type` sits at its start or right after the message, and the message's
    /// `usage` is its last key: both are near an end. The middle (message text, tool results) can
    /// be megabytes, so only a window at each end is searched.
    static let window = 4096

    static func head(_ line: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(rebasing: line[0..<min(line.count, window)])
    }

    static func tailStart(_ line: UnsafeRawBufferPointer) -> Int { max(0, line.count - window) }

    /// Cheap test before parsing: only assistant lines are interesting (user lines carry whole tool
    /// results and are rejected after looking at their two ends).
    public static func mightContainUsage(_ line: UnsafeRawBufferPointer) -> Bool {
        JSONScan.find(assistantType, in: line, from: tailStart(line)) != nil || JSONScan.find(assistantType, in: head(line)) != nil
    }

    /// The message's usage: its last key. Newer versions append `wireToolInputs` (copies of tool
    /// inputs, sometimes whole files) after the message, so the usage is the last one before it.
    static func usage(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        func parse(_ d: Data?) -> [String: Any]? {
            guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["input_tokens"] != nil || o["output_tokens"] != nil else { return nil }
            return o
        }
        let tail = UnsafeRawBufferPointer(rebasing: line[tailStart(line)...])
        if let at = JSONScan.findLast(usageKey, in: tail),
           JSONScan.find(wireKey, in: UnsafeRawBufferPointer(rebasing: tail[at...])) == nil,
           let o = parse(JSONScan.object(usageKey, in: tail, last: true)) {
            return o
        }
        let limit = JSONScan.find(wireKey, in: line) ?? line.count
        return parse(JSONScan.object(usageKey, in: UnsafeRawBufferPointer(rebasing: line[0..<limit]), last: true))
    }

    public static func entry(from line: Data) -> AIUsageEntry? {
        line.withUnsafeBytes { entry(from: $0) }
    }

    /// Fast path: the line's own keys come after the message (requestId, type, timestamp), the
    /// message's first keys are model and id, and its usage comes after its content. Falls back to
    /// a full parse if anything is missing.
    public static func entry(from line: UnsafeRawBufferPointer) -> AIUsageEntry? {
        guard mightContainUsage(line) else { return nil }
        if let quick = quickEntry(line) { return quick }
        return fullEntry(Data(line))
    }

    static func quickEntry(_ line: UnsafeRawBufferPointer) -> AIUsageEntry? {
        let h = head(line), tail = tailStart(line)
        let tailBuf = UnsafeRawBufferPointer(rebasing: line[tail...])
        guard let message = JSONScan.find(messageKey, in: h),
              let model = JSONScan.string(modelKey, in: h, from: message),
              let usage = usage(line),
              let date = parseISODate(JSONScan.string(timestampKey, in: tailBuf, last: true)) else { return nil }
        let id = JSONScan.string(idKey, in: h, from: message)
        let request = JSONScan.string(requestKey, in: tailBuf, last: true)
        return make(model: model, usage: usage, date: date, id: id, request: request, cost: nil)
    }

    static func fullEntry(_ line: Data) -> AIUsageEntry? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              (o["type"] as? String) == "assistant",
              let message = o["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let date = parseISODate(o["timestamp"] as? String) else { return nil }
        return make(model: (message["model"] as? String) ?? "unknown", usage: usage, date: date, id: message["id"] as? String,
                    request: o["requestId"] as? String, cost: (o["costUSD"] as? NSNumber)?.doubleValue)
    }

    private static func make(model: String, usage: [String: Any], date: Date, id: String?, request: String?, cost: Double?) -> AIUsageEntry? {
        let fast = (usage["speed"] as? String) == "fast"
        // Synthetic placeholder messages (errors, interruptions) carry no real usage.
        guard model != "<synthetic>" else { return nil }
        let created = int64(usage["cache_creation_input_tokens"])
        var write5m = created, write1h: Int64 = 0
        if let split = usage["cache_creation"] as? [String: Any] {
            write1h = int64(split["ephemeral_1h_input_tokens"])
            write5m = max(0, created - write1h)
        }
        let thinking = int64((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"])
        let t = TokenCounts(input: int64(usage["input_tokens"]), output: int64(usage["output_tokens"]),
                            cacheRead: int64(usage["cache_read_input_tokens"]), cacheWrite: write5m, cacheWrite1h: write1h,
                            reasoning: thinking)
        guard !t.isZero else { return nil }
        let key = (id != nil || request != nil) ? "\(id ?? "")|\(request ?? "")" : nil
        let prompt = t.input + t.cacheRead + t.cacheWrite + t.cacheWrite1h
        return AIUsageEntry(agent: .claudeCode, model: model, date: date, tokens: t, recordedCost: cost, dedupeKey: key,
                            promptTokens: prompt, fast: fast)
    }
}

/// Codex CLI: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. `turn_context` names the model;
/// `token_count` events carry the session's running total (and rate limits). Usage per turn is the
/// difference between consecutive totals, so a file is read as a stream with a little state.
public struct CodexLogReader: Codable, Equatable {
    public var model = "unknown"
    public var lastTotal: TokenCounts?
    /// A forked session may replay its parent's history first; usage stamped before the fork
    /// belongs to the parent (seen in older Codex versions).
    public var forkedAt: Date?
    /// OpenAI semantics: input includes cached input; output includes reasoning.
    private var lastRaw: [Int64]?

    public init() {}

    public enum Event: Equatable {
        case usage(AIUsageEntry)
        case limits(AIPlanStatus)
    }

    public static func mightMatter(_ line: Data) -> Bool {
        line.range(of: Data("\"token_count\"".utf8)) != nil || line.range(of: Data("\"turn_context\"".utf8)) != nil
            || line.range(of: Data("\"session_meta\"".utf8)) != nil
    }

    public mutating func read(_ line: Data) -> [Event] {
        guard Self.mightMatter(line) else { return [] }
        if line.range(of: Data("\"type\":\"turn_context\"".utf8)) != nil {
            // These lines can carry long instructions: take the model without parsing them.
            let m = line.withUnsafeBytes { raw -> String? in
                guard let payload = JSONScan.find(JSONScan.objectKey("payload"), in: raw) else { return nil }
                return JSONScan.string(JSONScan.key("model"), in: raw, from: payload)
            }
            if let m, !m.isEmpty { model = m }
            return []
        }
        if line.range(of: Data("\"type\":\"session_meta\"".utf8)) != nil {
            // These lines can carry long instructions too: read only the fork marker.
            line.withUnsafeBytes { raw in
                guard let payload = JSONScan.find(JSONScan.objectKey("payload"), in: raw),
                      JSONScan.string(JSONScan.key("forked_from_id"), in: raw, from: payload) != nil else { return }
                forkedAt = parseISODate(JSONScan.string(JSONScan.key("timestamp"), in: raw, from: payload))
            }
            return []
        }
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = o["payload"] as? [String: Any] else { return [] }
        guard (payload["type"] as? String) == "token_count",
              let date = parseISODate(o["timestamp"] as? String) else { return [] }
        let replayed = forkedAt.map { date < $0 } ?? false
        var events: [Event] = []
        if let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
            let raw = [int64(total["input_tokens"]), int64(total["cached_input_tokens"]), int64(total["output_tokens"]),
                       int64(total["reasoning_output_tokens"]), int64(total["cache_write_input_tokens"])]
            // Totals only grow within a session; a smaller one means a fresh count started.
            let previous = (lastRaw.map { zip(raw, $0).allSatisfy { $0 >= $1 } } ?? false) ? lastRaw! : [0, 0, 0, 0, 0]
            let d = zip(raw, previous).map { $0 - $1 }
            lastRaw = raw
            let cached = d[1], write = d[4]
            let t = TokenCounts(input: max(0, d[0] - cached - write), output: d[2], cacheRead: cached, cacheWrite: write, reasoning: d[3])
            if !replayed {
                lastTotal = (lastTotal ?? TokenCounts()) + t
                if !t.isZero {
                    events.append(.usage(AIUsageEntry(agent: .codex, model: model, date: date, tokens: t,
                                                      promptTokens: t.input + t.cacheRead + t.cacheWrite)))
                }
            }
        }
        if let limits = payload["rate_limits"] as? [String: Any], !replayed,
           (limits["limit_id"] as? String).map({ $0 == "codex" }) ?? true {
            var windows: [AIPlanWindow] = []
            for key in ["primary", "secondary"] {
                guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = Int(int64(w["window_minutes"]))
                var reset: Date?
                if let at = (w["resets_at"] as? NSNumber)?.doubleValue { reset = Date(timeIntervalSince1970: at) }
                else if let inSec = (w["resets_in_seconds"] as? NSNumber)?.doubleValue { reset = date.addingTimeInterval(inSec) }
                windows.append(AIPlanWindow(minutes: minutes, usedPercent: used, resetsAt: reset))
            }
            let credits = (limits["credits"] as? [String: Any]).flatMap { c -> Double? in
                guard (c["has_credits"] as? Bool) == true, (c["unlimited"] as? Bool) != true else { return nil }
                return (c["balance"] as? NSNumber)?.doubleValue ?? Double((c["balance"] as? String) ?? "")
            }
            if !windows.isEmpty || credits != nil {
                events.append(.limits(AIPlanStatus(agent: .codex, plan: limits["plan_type"] as? String, windows: windows,
                                                   credits: credits, updated: date)))
            }
        }
        return events
    }
}

/// OpenCode: assistant rows of `message` in ~/.local/share/opencode/opencode.db, whose `data`
/// JSON carries tokens, cost (OpenCode prices requests itself), model and creation time.
public enum OpenCodeLog {
    public static func entry(fromMessageData data: Data) -> AIUsageEntry? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["role"] as? String) == "assistant",
              let tokens = o["tokens"] as? [String: Any],
              let created = ((o["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue else { return nil }
        let cache = tokens["cache"] as? [String: Any]
        let reasoning = int64(tokens["reasoning"])
        let t = TokenCounts(input: int64(tokens["input"]), output: int64(tokens["output"]) + reasoning,
                            cacheRead: int64(cache?["read"]), cacheWrite: int64(cache?["write"]), reasoning: reasoning)
        guard !t.isZero else { return nil }
        let cost = (o["cost"] as? NSNumber)?.doubleValue
        return AIUsageEntry(agent: .openCode, model: (o["modelID"] as? String) ?? "unknown",
                            date: Date(timeIntervalSince1970: created / 1000), tokens: t,
                            recordedCost: (cost ?? 0) > 0 ? cost : nil)
    }
}

/// Gemini CLI: ~/.gemini/tmp/<project>/chats/session-*.jsonl (older sessions: one .json). Model
/// replies are `type: "gemini"` messages with `tokens`; a message is written again once its
/// tokens arrive, so the last line per id wins (the engine adds only growth). Gemini's `input`
/// includes cached tokens, `thoughts` come on top of `output`, and `tool` prompt tokens bill as
/// input.
public enum GeminiLog {
    public static func entries(from data: Data) -> [AIUsageEntry] {
        guard let o = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let message = o as? [String: Any], message["tokens"] != nil { return entry(message).map { [$0] } ?? [] }
        let messages = ((o as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
        return messages.compactMap(entry)
    }

    static func entry(_ m: [String: Any]) -> AIUsageEntry? {
        guard (m["type"] as? String) == "gemini", let tokens = m["tokens"] as? [String: Any],
              let date = parseISODate(m["timestamp"] as? String) else { return nil }
        let input = int64(tokens["input"]), cached = int64(tokens["cached"]), thoughts = int64(tokens["thoughts"])
        let t = TokenCounts(input: max(0, input - cached) + int64(tokens["tool"]), output: int64(tokens["output"]) + thoughts,
                            cacheRead: cached, reasoning: thoughts)
        guard !t.isZero else { return nil }
        return AIUsageEntry(agent: .geminiCLI, model: (m["model"] as? String) ?? "unknown", date: date, tokens: t,
                            dedupeKey: (m["id"] as? String).map { "gemini|\($0)" }, promptTokens: input + int64(tokens["tool"]))
    }
}

/// Qwen Code: ~/.qwen/projects/<project>/chats/<session>.jsonl, Gemini-style `usageMetadata` on
/// assistant records (prompt includes cached tokens; thoughts may also be inside candidates).
public enum QwenLog {
    public static func entry(from data: Data) -> AIUsageEntry? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["type"] as? String) == "assistant", let u = o["usageMetadata"] as? [String: Any],
              let date = parseISODate(o["timestamp"] as? String) else { return nil }
        let prompt = int64(u["promptTokenCount"]), cached = int64(u["cachedContentTokenCount"])
        let candidates = int64(u["candidatesTokenCount"]), thoughts = int64(u["thoughtsTokenCount"])
        // When the total says thoughts are already inside candidates, don't add them twice.
        let total = int64(u["totalTokenCount"])
        let output = total > 0 && total < prompt + candidates + thoughts ? candidates : candidates + thoughts
        let t = TokenCounts(input: max(0, prompt - cached), output: output, cacheRead: cached, reasoning: thoughts)
        guard !t.isZero else { return nil }
        let id = (o["uuid"] as? String) ?? (o["id"] as? String)
        return AIUsageEntry(agent: .qwenCode, model: (o["model"] as? String) ?? "unknown", date: date, tokens: t,
                            dedupeKey: id.map { "qwen|\($0)" }, promptTokens: prompt)
    }
}

/// Kimi Code: ~/.kimi-code/sessions/<ws>/<session>/agents/<agent>/wire.jsonl, `usage.record`
/// lines with input split into new, cache-read and cache-creation tokens; time in milliseconds.
public enum KimiLog {
    public static func entry(from data: Data) -> AIUsageEntry? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (o["type"] as? String) == "usage.record", let u = o["usage"] as? [String: Any],
              let ms = (o["time"] as? NSNumber)?.doubleValue else { return nil }
        let t = TokenCounts(input: int64(u["inputOther"]), output: int64(u["output"]), cacheRead: int64(u["inputCacheRead"]),
                            cacheWrite: int64(u["inputCacheCreation"]))
        guard !t.isZero else { return nil }
        var model = (o["model"] as? String) ?? "unknown"
        if let slash = model.lastIndex(of: "/") { model = String(model[model.index(after: slash)...]) }
        return AIUsageEntry(agent: .kimiCode, model: model, date: Date(timeIntervalSince1970: ms / 1000), tokens: t,
                            promptTokens: t.input + t.cacheRead + t.cacheWrite)
    }
}

// MARK: - The book: sums per day, agent and model

public enum AIRange: String, CaseIterable, Codable {
    case today, week, month, quarter, year

    /// First day of the range containing `now`, in `calendar` (weeks start on the calendar's
    /// first weekday).
    public func start(containing now: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: now)
        switch self {
        case .today: return day
        case .week: return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? day
        case .month: return calendar.dateInterval(of: .month, for: now)?.start ?? day
        case .quarter:
            let m = calendar.component(.month, from: now)
            var c = calendar.dateComponents([.year], from: now)
            c.month = (m - 1) / 3 * 3 + 1
            c.day = 1
            return calendar.date(from: c) ?? day
        case .year: return calendar.dateInterval(of: .year, for: now)?.start ?? day
        }
    }
}

/// Usage sums by local day ("yyyy-MM-dd"), then by "agent|model[|long]". Small and bounded: a
/// year of daily sums for a handful of models.
public struct AIUsageBook: Codable, Equatable {
    public var days: [String: [String: TokenCounts]] = [:]
    /// Costs an agent recorded itself, by the same keys.
    public var recordedCosts: [String: [String: Double]] = [:]

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        guard calendar.identifier == .gregorian else {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        // Local day from the UTC offset (cached per hour: it only changes at DST transitions).
        let t = date.timeIntervalSince1970
        let hour = Int((t / 3600).rounded(.down))
        let offset: Int
        if let cached = OffsetCache.lookup(hour, calendar.timeZone) { offset = cached }
        else { offset = calendar.timeZone.secondsFromGMT(for: date); OffsetCache.store(hour, calendar.timeZone, offset) }
        let days = Int(((t + Double(offset)) / 86_400).rounded(.down))
        let c = civilFromDays(days)
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(c.year)-\(two(c.month))-\(two(c.day))"
    }

    public static func key(_ e: AIUsageEntry) -> String {
        "\(e.agent.rawValue)|\(e.model)" + (e.tier > 0 ? "|t\(e.tier)" : "") + (e.fast ? "|fast" : "")
    }

    public static func parse(key: String) -> (agent: AIAgent, model: String, tier: Int, fast: Bool)? {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let agent = AIAgent(rawValue: parts[0]) else { return nil }
        var tier = 0, fast = false
        for p in parts.dropFirst(2) {
            if p == "fast" { fast = true } else if p == "long" { tier = 200 } else if p.hasPrefix("t"), let t = Int(p.dropFirst()) { tier = t }
        }
        return (agent, parts[1], tier, fast)
    }

    public mutating func add(_ e: AIUsageEntry, calendar: Calendar) {
        let day = Self.dayKey(e.date, calendar: calendar), key = Self.key(e)
        days[day, default: [:]][key, default: TokenCounts()] += e.tokens
        if let c = e.recordedCost { recordedCosts[day, default: [:]][key, default: 0] += c }
    }

    /// Replaces everything one agent contributed (for sources re-read as a whole).
    public mutating func replace(_ agent: AIAgent, with entries: [AIUsageEntry], calendar: Calendar) {
        let prefix = agent.rawValue + "|"
        for d in Array(days.keys) {
            days[d] = days[d]?.filter { !$0.key.hasPrefix(prefix) }
            if days[d]?.isEmpty == true { days[d] = nil }
        }
        for d in Array(recordedCosts.keys) {
            recordedCosts[d] = recordedCosts[d]?.filter { !$0.key.hasPrefix(prefix) }
            if recordedCosts[d]?.isEmpty == true { recordedCosts[d] = nil }
        }
        entries.forEach { add($0, calendar: calendar) }
    }

    /// Drops days before `oldest` ("yyyy-MM-dd"), so the book never grows without bound.
    public mutating func prune(before oldest: String) {
        days = days.filter { $0.key >= oldest }
        recordedCosts = recordedCosts.filter { $0.key >= oldest }
    }

    public struct Total: Equatable {
        public var tokens = TokenCounts()
        public var cost: Double = 0
        /// Tokens of models without a known price (their cost is left out of `cost`).
        public var unpricedTokens: Int64 = 0
        public init() {}
    }

    /// Sums days from `from` ("yyyy-MM-dd", inclusive) for the given agents.
    public func total(from: String, through: String? = nil, agents: Set<AIAgent>, prices: (String) -> ModelPrice?) -> Total {
        var out = Total()
        for (day, keys) in days where day >= from && (through.map { day <= $0 } ?? true) {
            for (key, t) in keys {
                guard let k = Self.parse(key: key), agents.contains(k.agent) else { continue }
                out.tokens += t
                if let recorded = recordedCosts[day]?[key] {
                    out.cost += recorded
                } else if let p = prices(k.model) {
                    out.cost += AIPricing.cost(t, p, tier: k.tier, fast: k.fast)
                } else {
                    out.unpricedTokens += t.total
                }
            }
        }
        return out
    }

    /// Per-day totals for the last `count` days ending today (oldest first), for sparklines.
    public func daily(last count: Int, now: Date, calendar: Calendar, agents: Set<AIAgent>,
                      prices: (String) -> ModelPrice?) -> [Total] {
        (0..<count).reversed().map { back in
            let d = calendar.date(byAdding: .day, value: -back, to: now) ?? now
            let key = Self.dayKey(d, calendar: calendar)
            return total(from: key, through: key, agents: agents, prices: prices)
        }
    }

    /// Models by cost (then tokens) since `from`, for the dropdown.
    public func models(from: String, agents: Set<AIAgent>, prices: (String) -> ModelPrice?) -> [(agent: AIAgent, model: String, total: Total)] {
        var sums: [String: (AIAgent, String, Total)] = [:]
        for (day, keys) in days where day >= from {
            for (key, t) in keys {
                guard let k = Self.parse(key: key), agents.contains(k.agent) else { continue }
                let id = "\(k.agent.rawValue)|\(k.model)"
                var entry = sums[id] ?? (k.agent, k.model, Total())
                entry.2.tokens += t
                if let recorded = recordedCosts[day]?[key] { entry.2.cost += recorded }
                else if let p = prices(k.model) { entry.2.cost += AIPricing.cost(t, p, tier: k.tier, fast: k.fast) }
                else { entry.2.unpricedTokens += t.total }
                sums[id] = entry
            }
        }
        return sums.values.map { (agent: $0.0, model: $0.1, total: $0.2) }
            .sorted { ($0.total.cost, $0.total.tokens.total) > ($1.total.cost, $1.total.tokens.total) }
    }
}

/// Last UTC offset seen per hour and time zone (dayKey is called for every log entry).
enum OffsetCache {
    private static var hour = Int.min, zone = "", offset = 0
    private static let lock = NSLock()
    static func lookup(_ h: Int, _ tz: TimeZone) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return h == hour && tz.identifier == zone ? offset : nil
    }
    static func store(_ h: Int, _ tz: TimeZone, _ o: Int) {
        lock.lock(); defer { lock.unlock() }
        hour = h; zone = tz.identifier; offset = o
    }
}

// MARK: - Prices

/// USD per token, LiteLLM-style. Long-context fields apply to requests above the model's tier
/// threshold (200k prompt tokens for Claude Sonnet).
public struct ModelPrice: Codable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var cacheWrite1h: Double?
    public var inputLong: Double?
    public var outputLong: Double?
    public var cacheReadLong: Double?
    public var cacheWriteLong: Double?
    /// Prompt size above which the long prices apply to the whole request (100k, 200k or 272k).
    public var threshold: Int?
    /// Fast-mode multiplier (Claude).
    public var fast: Double?

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, cacheWrite1h: Double? = nil,
                inputLong: Double? = nil, outputLong: Double? = nil, cacheReadLong: Double? = nil, cacheWriteLong: Double? = nil,
                threshold: Int? = nil, fast: Double? = nil) {
        self.threshold = threshold
        self.fast = fast
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.inputLong = inputLong
        self.outputLong = outputLong
        self.cacheReadLong = cacheReadLong
        self.cacheWriteLong = cacheWriteLong
    }
}

public enum AIPricing {
    public static func cost(_ t: TokenCounts, _ p: ModelPrice, tier: Int = 0, fast: Bool = false) -> Double {
        let long = p.threshold.map { tier * 1000 >= $0 } ?? (tier >= 200 && p.inputLong != nil)
        let base = cost(t, p, long: long)
        return fast ? base * (p.fast ?? 2) : base
    }

    public static func cost(_ t: TokenCounts, _ p: ModelPrice, long: Bool) -> Double {
        let input = long ? (p.inputLong ?? p.input) : p.input
        let output = long ? (p.outputLong ?? p.output) : p.output
        let read = long ? (p.cacheReadLong ?? p.cacheRead) : p.cacheRead
        let write = long ? (p.cacheWriteLong ?? p.cacheWrite) : p.cacheWrite
        // Anthropic bills 1-hour cache writes at 2x input; fall back to that if no explicit price.
        let write1h = p.cacheWrite1h ?? input * 2
        return Double(t.input) * input + Double(t.output) * output + Double(t.cacheRead) * read
            + Double(t.cacheWrite) * write + Double(t.cacheWrite1h) * write1h
    }

    /// Finds a model's price: exact name, then without a provider prefix or a date suffix.
    public static func lookup(_ model: String, in table: [String: ModelPrice]) -> ModelPrice? {
        var name = model.lowercased()
        if let p = table[name] { return p }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let p = table[name] { return p }
        // claude-sonnet-4-5-20250929 → claude-sonnet-4-5
        if let r = name.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(name[..<r.lowerBound])
            if let p = table[base] { return p }
            name = base
        }
        // Dated or suffixed variants in the table (e.g. gpt-5-codex vs gpt-5-codex-latest).
        let candidates = table.keys.filter { $0.hasPrefix(name + "-") || name.hasPrefix($0 + "-") }
        if let best = candidates.max(by: { $0.count < $1.count }) { return table[best] }
        return nil
    }
}

// MARK: - Display

public enum AIFormat {
    /// 845, 12.3K, 4.5M, 1.2B: tokens in the menu bar.
    public static func tokens(_ n: Int64) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000: return "\(n)"
        case ..<10_000: return String(format: "%.1fK", v / 1_000)
        case ..<1_000_000: return "\(Int((v / 1_000).rounded()))K"
        case ..<10_000_000: return String(format: "%.1fM", v / 1_000_000)
        case ..<1_000_000_000: return "\(Int((v / 1_000_000).rounded()))M"
        default: return String(format: "%.1fB", v / 1_000_000_000)
        }
    }

    /// $0.42, $12.34, $123, $1.2K.
    public static func cost(_ usd: Double) -> String {
        switch usd {
        case ..<100: return String(format: "$%.2f", usd)
        case ..<1_000: return "$\(Int(usd.rounded()))"
        default: return String(format: "$%.1fK", usd / 1_000)
        }
    }

    /// Like `cost`, in any currency (€12.34, €1.2K).
    public static func compactMoney(_ v: Double, currency: String) -> String {
        let usd = cost(v)
        return currency == "USD" ? usd : symbol(currency) + usd.dropFirst()
    }

    /// $2,185.57; whole units from 1,000 up.
    public static func money(_ v: Double, currency: String) -> String {
        let digits = abs(v) >= 1_000 ? 0 : 2
        let grouped = String(format: "%.\(digits)f", v).split(separator: ".", omittingEmptySubsequences: false)
        var whole = String(grouped[0])
        var out = ""
        while whole.count > 3 {
            out = "," + whole.suffix(3) + out
            whole.removeLast(3)
        }
        out = whole + out + (grouped.count > 1 ? "." + grouped[1] : "")
        return symbol(currency) + out
    }

    private static func symbol(_ currency: String) -> String {
        switch currency {
        case "USD": return "$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY", "CNY": return "¥"
        default: return currency + " "
        }
    }
}

// MARK: - What the menu bar shows

/// One agent's (or all agents') numbers for the menu bar item, computed when usage changes.
public struct AIFigure: Equatable {
    public var tokens: Int64 = 0
    public var cost: Double = 0
    /// Part of the tokens has no known price, so `cost` is a lower bound.
    public var partlyPriced = false
    /// Plan windows, fullest first (only agents that report limits).
    public var windows: [AIPlanWindow] = []
    /// Usage credits, for the agent whose plan has them.
    public var spend: AISpend?
    public init() {}
}

public struct AIDisplay: Equatable {
    public var total = AIFigure()
    public var perAgent: [(agent: AIAgent, figure: AIFigure)] = []
    public var range: AIRange = .today
    public init() {}

    public static func == (a: AIDisplay, b: AIDisplay) -> Bool {
        a.total == b.total && a.range == b.range && a.perAgent.map(\.agent) == b.perAgent.map(\.agent)
            && a.perAgent.map(\.figure) == b.perAgent.map(\.figure)
    }

    public static func make(book: AIUsageBook, plans: [AIAgent: AIPlanStatus], agents: [AIAgent], range: AIRange,
                            now: Date, calendar: Calendar, prices: (String) -> ModelPrice?) -> AIDisplay {
        let from = AIUsageBook.dayKey(range.start(containing: now, calendar: calendar), calendar: calendar)
        func figure(_ set: Set<AIAgent>) -> AIFigure {
            let t = book.total(from: from, agents: set, prices: prices)
            var f = AIFigure()
            f.tokens = t.tokens.total
            f.cost = t.cost
            f.partlyPriced = t.unpricedTokens > 0
            f.windows = set.compactMap { plans[$0] }.flatMap { $0.current(now: now) }.sorted { $0.usedPercent > $1.usedPercent }
            f.spend = AIAgent.allCases.lazy.filter(set.contains).compactMap { plans[$0]?.spend }.first
            return f
        }
        var d = AIDisplay()
        d.range = range
        d.total = figure(Set(agents))
        d.perAgent = agents.map { ($0, figure([$0])) }
        return d
    }
}

public extension Settings {
    /// The range the menu bar item shows.
    var aiRange: AIRange {
        get { defaults.string(forKey: "ai.range").flatMap(AIRange.init(rawValue:)) ?? .today }
        set { defaults.set(newValue.rawValue, forKey: "ai.range"); post("stats") }
    }

    /// Agents counted; empty means every agent found on this Mac.
    var aiAgents: Set<AIAgent> {
        get { Set((defaults.stringArray(forKey: "ai.agents") ?? []).compactMap(AIAgent.init(rawValue:))) }
        set { defaults.set(AIAgent.allCases.filter(newValue.contains).map(\.rawValue), forKey: "ai.agents"); post("stats") }
    }

    /// One segment per agent in the menu bar instead of their total.
    var aiPerAgent: Bool {
        get { defaults.bool(forKey: "ai.perAgent") }
        set { defaults.set(newValue, forKey: "ai.perAgent"); post("stats") }
    }

    /// Fetch LiteLLM's public price list now and then (on by default while AI usage is on).
    var aiPricesOnline: Bool {
        get { defaults.object(forKey: "ai.pricesOnline") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "ai.pricesOnline"); post("stats") }
    }

    /// Plan limits as what is left instead of what is used.
    var aiPlanLeft: Bool {
        get { defaults.bool(forKey: "ai.planLeft") }
        set { defaults.set(newValue, forKey: "ai.planLeft"); post("stats") }
    }
}

// MARK: - Price tables

public enum AIPriceTable {
    /// BarTap's compact table: {"fetched": "...", "models": {name: {i, o, cr, cw, cw1h, iL, oL, crL, cwL, t, f}}}.
    public static func decode(_ data: Data) -> (fetched: String, models: [String: ModelPrice])? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = o["models"] as? [String: [String: Any]] else { return nil }
        var out: [String: ModelPrice] = [:]
        for (name, m) in models {
            func d(_ k: String) -> Double? { (m[k] as? NSNumber)?.doubleValue }
            guard let input = d("i"), let output = d("o") else { continue }
            // Without explicit cache prices, cached tokens cost the input rate.
            out[name] = ModelPrice(input: input, output: output, cacheRead: d("cr") ?? input, cacheWrite: d("cw") ?? input,
                                   cacheWrite1h: d("cw1h"), inputLong: d("iL"), outputLong: d("oL"), cacheReadLong: d("crL"),
                                   cacheWriteLong: d("cwL"), threshold: (m["t"] as? NSNumber)?.intValue, fast: d("f"))
        }
        return ((o["fetched"] as? String) ?? "", out)
    }

    public static let providers: Set<String> = ["anthropic", "openai", "gemini", "vertex_ai-language-models", "xai", "deepseek",
                                                "mistral", "moonshot", "zai", "minimax"]

    /// Converts LiteLLM's model_prices_and_context_window.json into BarTap's compact table:
    /// chat models of the main providers, under their plain names.
    public static func compact(fromLiteLLM data: Data, fetched: String) -> Data? {
        guard let all = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tiers: [(suffix: String, threshold: Int)] = [("_above_100k_tokens", 100_000), ("_above_200k_tokens", 200_000), ("_above_272k_tokens", 272_000)]
        var models: [String: [String: Any]] = [:]
        var fromVertex = Set<String>()
        for (key, value) in all {
            guard let e = value as? [String: Any], let provider = e["litellm_provider"] as? String, providers.contains(provider),
                  ["chat", "responses", nil].contains(e["mode"] as? String),
                  let input = (e["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let output = (e["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            var name = key.lowercased()
            if let slash = name.firstIndex(of: "/") {
                let prefix = String(name[..<slash]), rest = String(name[name.index(after: slash)...])
                guard ["gemini", "xai", "deepseek", "mistral", "moonshot", "zai", "minimax"].contains(prefix), !rest.contains("/") else { continue }
                name = rest
            }
            if models[name] != nil, provider == "vertex_ai-language-models" { continue }
            if fromVertex.contains(name), provider != "vertex_ai-language-models" { models[name] = nil }
            var row: [String: Any] = ["i": input, "o": output]
            func copy(_ src: String, _ dst: String) { if let v = (e[src] as? NSNumber)?.doubleValue { row[dst] = v } }
            copy("cache_read_input_token_cost", "cr")
            copy("cache_creation_input_token_cost", "cw")
            copy("cache_creation_input_token_cost_above_1hr", "cw1h")
            for t in tiers where e["input_cost_per_token" + t.suffix] != nil || e["output_cost_per_token" + t.suffix] != nil {
                copy("input_cost_per_token" + t.suffix, "iL")
                copy("output_cost_per_token" + t.suffix, "oL")
                copy("cache_read_input_token_cost" + t.suffix, "crL")
                copy("cache_creation_input_token_cost" + t.suffix, "cwL")
                row["t"] = t.threshold
                break
            }
            if let fast = ((e["provider_specific_entry"] as? [String: Any])?["fast"] as? NSNumber)?.doubleValue { row["f"] = fast }
            models[name] = row
            if provider == "vertex_ai-language-models" { fromVertex.insert(name) }
        }
        return try? JSONSerialization.data(withJSONObject: ["source": "LiteLLM model_prices_and_context_window.json", "fetched": fetched,
                                                             "models": models], options: [.sortedKeys])
    }
}

// MARK: - Claude's own plan cache

/// Claude Code caches its plan usage in ~/.claude.json (`cachedUsageUtilization`): read locally,
/// no credentials and no network. Undocumented, so every field is optional.
public enum ClaudePlanCache {
    public static func status(fromClaudeJSON data: Data) -> AIPlanStatus? {
        // The file is pretty-printed and about 100 KB: parse it whole (it is read at most once a
        // minute, and only after Claude Code rewrote it).
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = o["utilization"] as? [String: Any] else { return nil }
        let fetched = ((o["fetchedAtMs"] as? NSNumber)?.doubleValue).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        func window(_ key: String, minutes: Int, scope: String? = nil) -> AIPlanWindow? {
            guard let w = utilization[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return AIPlanWindow(minutes: minutes, usedPercent: used, resetsAt: resetDate(w["resets_at"]), scope: scope)
        }
        var windows = [window("five_hour", minutes: 300), window("seven_day", minutes: 10_080),
                       window("seven_day_opus", minutes: 10_080, scope: "Opus"), window("seven_day_sonnet", minutes: 10_080, scope: "Sonnet")]
            .compactMap { $0 }
        // The newer list of limits: weekly ones, some scoped to a model, and the session (5-hour)
        // limit, which repeats five_hour. Other kinds are not shown.
        for l in (o["limits"] as? [[String: Any]]) ?? (utilization["limits"] as? [[String: Any]]) ?? [] {
            guard let percent = (l["percent"] as? NSNumber)?.doubleValue, let kind = l["kind"] as? String else { continue }
            let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let minutes: Int
            if kind.hasPrefix("weekly") { minutes = 10_080 } else if kind == "session" { minutes = 300 } else { continue }
            guard !windows.contains(where: { $0.minutes == minutes && $0.scope == model }) else { continue }
            windows.append(AIPlanWindow(minutes: minutes, usedPercent: percent, resetsAt: resetDate(l["resets_at"]), scope: model))
        }
        // Usage credits ("extra usage"): amounts in minor units (cents).
        var spend: AISpend?
        if let e = utilization["extra_usage"] as? [String: Any], e["is_enabled"] as? Bool == true,
           let usedMinor = (e["used_credits"] as? NSNumber)?.doubleValue {
            let scale = pow(10, Double((e["decimal_places"] as? NSNumber)?.intValue ?? 2))
            spend = AISpend(used: usedMinor / scale, limit: (e["monthly_limit"] as? NSNumber).map { $0.doubleValue / scale },
                            currency: e["currency"] as? String ?? "USD", limitReached: e["spend_limit_reached"] as? Bool ?? false)
        } else if let s = utilization["spend"] as? [String: Any], s["enabled"] as? Bool == true, let used = money(s["used"]) {
            let limit = money(s["limit"])?.value
            spend = AISpend(used: used.value, limit: limit, currency: used.currency ?? "USD",
                            limitReached: limit.map { used.value >= $0 } ?? false)
        }
        let remaining = ((utilization["five_hour"] as? [String: Any])?["remaining_dollars"] as? NSNumber)?.doubleValue
        guard !windows.isEmpty || remaining != nil || spend != nil else { return nil }
        return AIPlanStatus(agent: .claudeCode, plan: nil, windows: windows, credits: remaining, updated: fetched, spend: spend)
    }

    /// {"amount_minor": 218557, "exponent": 2, "currency": "USD"} → 2185.57.
    private static func money(_ v: Any?) -> (value: Double, currency: String?)? {
        guard let m = v as? [String: Any], let minor = (m["amount_minor"] as? NSNumber)?.doubleValue else { return nil }
        return (minor / pow(10, Double((m["exponent"] as? NSNumber)?.intValue ?? 2)), m["currency"] as? String)
    }

    private static func resetDate(_ v: Any?) -> Date? {
        if let s = v as? String { return parseISODate(s) }
        if let n = (v as? NSNumber)?.doubleValue { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        return nil
    }
}
