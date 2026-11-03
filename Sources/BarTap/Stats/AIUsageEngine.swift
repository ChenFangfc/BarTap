import Foundation
import CoreServices
import SQLite3
import BarTapCore

/// Where each agent keeps its history on this Mac.
enum AISources {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func roots(_ agent: AIAgent) -> [URL] {
        switch agent {
        case .claudeCode: return [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
        case .codex: return [home.appendingPathComponent(".codex/sessions"), home.appendingPathComponent(".codex/archived_sessions")]
        case .geminiCLI: return [home.appendingPathComponent(".gemini/tmp")]
        case .openCode: return [home.appendingPathComponent(".local/share/opencode")]
        case .kiloCode: return [home.appendingPathComponent(".local/share/kilo")]
        case .qwenCode: return [home.appendingPathComponent(".qwen/projects")]
        case .kimiCode: return [home.appendingPathComponent(".kimi-code/sessions")]
        }
    }

    /// Agents that keep their history in SQLite (OpenCode and its fork Kilo share the schema).
    static func database(_ agent: AIAgent) -> URL? {
        switch agent {
        case .openCode: return home.appendingPathComponent(".local/share/opencode/opencode.db")
        case .kiloCode: return home.appendingPathComponent(".local/share/kilo/kilo.db")
        default: return nil
        }
    }

    static var claudeJSON: URL { home.appendingPathComponent(".claude.json") }

    /// Agents with a history on this Mac.
    static func detected() -> Set<AIAgent> {
        Set(AIAgent.allCases.filter { a in
            if let db = database(a) { return FileManager.default.fileExists(atPath: db.path) }
            return roots(a).contains { FileManager.default.fileExists(atPath: $0.path) }
        })
    }
}

/// Reads the agents' logs and keeps per-day sums. Only new bytes are ever read: each file's
/// read position is remembered (and saved), and FSEvents says which files changed, so a 7 GB
/// Claude Code history is read once and then only its appended lines. Everything kept is
/// bounded: sums and de-duplication fingerprints older than the longest range are dropped.
final class AIUsageEngine {
    struct Snapshot {
        var book = AIUsageBook()
        var plans: [AIAgent: AIPlanStatus] = [:]
        var detected: Set<AIAgent> = []
        /// 0…1 while the first read of the history is running.
        var progress: Double?
        var updated = Date()
    }

    /// Called on the main thread after anything changed.
    var onUpdate: ((Snapshot) -> Void)?

    private struct FileState: Codable {
        var offset: UInt64
        var codex: CodexLogReader?
    }

    private struct Saved: Codable {
        var version = 1
        var book = AIUsageBook()
        var files: [String: FileState] = [:]
        var plans: [AIPlanStatus] = []
        var fingerprints: [String: Data] = [:]
    }

    private let queue = DispatchQueue(label: "bartap.ai", qos: .utility)
    private var book = AIUsageBook()
    private var files: [String: FileState] = [:]
    private var plans: [AIAgent: AIPlanStatus] = [:]
    private var fingerprints: [String: Set<UInt64>] = [:]
    /// The last messages per file, to catch a repeated line whose output grew while streaming.
    /// Kept for the most recently read files only: streaming happens in the active sessions.
    private var recent: [String: [UInt64: (day: String, key: String, tokens: TokenCounts)]] = [:]
    private var recentOrder: [String: [UInt64]] = [:]
    private var recentFiles: [String] = []
    private var detected: Set<AIAgent> = []
    private var stream: FSEventStreamRef?
    private var changed = Set<String>()
    private var databasesDirty = true
    private var claudeTimer: DispatchSourceTimer?
    private var parsedSinceRelief = 0.0
    private var detectTimer: DispatchSourceTimer?
    private var claudeJSONStamp: Date?
    private var scheduled = false
    private var running = false
    private var dirtySince: Date?
    private let calendar = Calendar.current

    /// Tests point this elsewhere.
    static var storeOverride: URL?
    static var storeURL: URL {
        storeOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarTap/ai-usage.json")
    }

    /// One full read, synchronously (the headless check in main.swift).
    func scanOnce() -> Snapshot {
        queue.sync {
            running = true
            load()
            detected = AISources.detected()
            fullScan()
            save()
            running = false
            return Snapshot(book: book, plans: plans, detected: detected, progress: nil, updated: Date())
        }
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            load()
            detected = AISources.detected()
            fullScan()
            startWatching()
            startClaudePlanChecks()
            startDetecting()
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            stopWatching()
            claudeTimer?.cancel()
            claudeTimer = nil
            detectTimer?.cancel()
            detectTimer = nil
            save()
            // Nothing stays in memory while the module is off.
            book = AIUsageBook(); files = [:]; fingerprints = [:]; recent = [:]; recentOrder = [:]; recentFiles = []; plans = [:]
        }
    }

    /// Saves now (on quit). Blocks briefly.
    func flush() { queue.sync { if running { save() } } }

    /// Plan limits from elsewhere (Claude's usage endpoint).
    func setPlan(_ status: AIPlanStatus) {
        queue.async { [self] in
            plans[status.agent] = status
            publish()
        }
    }

    // MARK: Reading

    private func retentionKey(now: Date = Date()) -> String {
        // The year, the week (which can start in December) and 90 days for the graph.
        let starts = [AIRange.year.start(containing: now, calendar: calendar), AIRange.week.start(containing: now, calendar: calendar),
                      calendar.date(byAdding: .day, value: -95, to: now) ?? now]
        return AIUsageBook.dayKey(starts.min() ?? now, calendar: calendar)
    }

    private func fullScan() {
        let oldest = retentionKey()
        let since = Self.date(fromKey: oldest, calendar: calendar)
        var todo: [(AIAgent, URL, UInt64)] = []
        var seen = Set<String>()
        for agent in AIAgent.allCases where detected.contains(agent) && AISources.database(agent) == nil {
            for root in AISources.roots(agent) {
                guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in e where Self.isLog(url.path, agent) {
                    guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                          v.isRegularFile == true, let size = v.fileSize else { continue }
                    seen.insert(url.path)
                    // A file last written before the oldest day shown can't hold anything we show.
                    if let m = v.contentModificationDate, m < since { continue }
                    if UInt64(size) > (files[url.path]?.offset ?? 0) || UInt64(size) < (files[url.path]?.offset ?? 0) {
                        todo.append((agent, url, UInt64(size)))
                    }
                }
            }
        }
        files = files.filter { seen.contains($0.key) }
        let totalBytes = max(1, todo.reduce(0) { $0 + Double($1.2 - min($1.2, files[$1.1.path]?.offset ?? 0)) })
        var done = 0.0
        var lastPublish = Date()
        let firstRead = todo.count > 50
        for (agent, url, size) in todo {
            let before = files[url.path]?.offset ?? 0
            read(agent, url)
            done += Double(size - min(size, before))
            if firstRead, Date().timeIntervalSince(lastPublish) > 0.5 {
                lastPublish = Date()
                publish(progress: done / totalBytes)
            }
        }
        readDatabases()
        readClaudePlan()
        prune()
        publish()
        markDirty()
        // A first read parses gigabytes in passing, and later reads add up (an agent's log grows
        // all day): give the freed memory back after a big read, and every 10 MB of small ones.
        parsedSinceRelief += totalBytes
        if firstRead || parsedSinceRelief > 10_000_000 {
            parsedSinceRelief = 0
            Memory.returnFreedPages(after: 1.0)
        }
    }

    /// Log files per agent (Gemini also kept whole sessions as .json before switching to JSONL).
    static func isLog(_ path: String, _ agent: AIAgent) -> Bool {
        switch agent {
        case .geminiCLI: return path.contains("/chats/") && (path.hasSuffix(".jsonl") || path.hasSuffix(".json"))
        case .qwenCode: return path.contains("/chats/") && path.hasSuffix(".jsonl")
        case .kimiCode: return path.hasSuffix("wire.jsonl")
        default: return path.hasSuffix(".jsonl")
        }
    }

    private func read(_ agent: AIAgent, _ url: URL) {
        let path = url.path
        var state = files[path] ?? FileState(offset: 0, codex: agent == .codex ? CodexLogReader() : nil)
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, UInt64(size) < state.offset {
            // Rewritten from the start: read it again (Claude entries are de-duplicated).
            state = FileState(offset: 0, codex: agent == .codex ? CodexLogReader() : nil)
        }
        let oldest = retentionKey()
        if agent == .geminiCLI, url.pathExtension == "json" {
            // A whole-session file, rewritten in place: read it again when it changes; message ids
            // keep it from counting twice.
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, UInt64(size) != files[path]?.offset,
                  let data = try? Data(contentsOf: url) else { return }
            for e in GeminiLog.entries(from: data) where AIUsageBook.dayKey(e.date, calendar: calendar) >= oldest { addDeduplicated(e, path: path) }
            files[path] = FileState(offset: UInt64(size), codex: nil)
            return
        }
        let prefilter: (UnsafeRawBufferPointer) -> Bool
        switch agent {
        case .claudeCode: prefilter = { ClaudeCodeLog.mightContainUsage($0) }
        case .codex: prefilter = { Self.contains($0, "\"token_count\"") || Self.contains($0, "\"turn_context\"") || Self.contains($0, "\"session_meta\"") }
        case .geminiCLI: prefilter = { Self.contains($0, "\"tokens\"") }
        case .qwenCode: prefilter = { Self.contains($0, "\"usageMetadata\"") }
        case .kimiCode: prefilter = { Self.contains($0, "\"usage.record\"") }
        case .openCode, .kiloCode: return
        }
        var codex = state.codex ?? CodexLogReader()
        state.offset = JSONLines.read(url, from: state.offset, prefilter: prefilter) { line in
            switch agent {
            case .claudeCode:
                if let e = ClaudeCodeLog.entry(from: line) { self.addClaude(e, path: path, oldest: oldest) }
            case .codex:
                for event in codex.read(Data(line)) {
                    switch event {
                    case .usage(let e): if AIUsageBook.dayKey(e.date, calendar: self.calendar) >= oldest { self.book.add(e, calendar: self.calendar) }
                    case .limits(let p): if (self.plans[.codex]?.updated ?? .distantPast) <= p.updated { self.plans[.codex] = p }
                    }
                }
            case .geminiCLI:
                for e in GeminiLog.entries(from: Data(line)) where AIUsageBook.dayKey(e.date, calendar: self.calendar) >= oldest {
                    self.addDeduplicated(e, path: path)
                }
            case .qwenCode:
                if let e = QwenLog.entry(from: Data(line)), AIUsageBook.dayKey(e.date, calendar: self.calendar) >= oldest { self.addDeduplicated(e, path: path) }
            case .kimiCode:
                if let e = KimiLog.entry(from: Data(line)), AIUsageBook.dayKey(e.date, calendar: self.calendar) >= oldest { self.book.add(e, calendar: self.calendar) }
            case .openCode, .kiloCode:
                break
            }
        }
        if agent == .codex { state.codex = codex }
        files[path] = state
    }

    private func addClaude(_ e: AIUsageEntry, path: String, oldest: String) {
        guard AIUsageBook.dayKey(e.date, calendar: calendar) >= oldest else { return }
        addDeduplicated(e, path: path)
    }

    /// Claude Code writes one line per content block, each repeating the message's usage, and a
    /// resumed session copies earlier lines into a new file: count each message once. A repeat
    /// whose output grew (written while streaming) adds only the difference.
    private func addDeduplicated(_ e: AIUsageEntry, path: String) {
        guard let id = e.dedupeKey else { book.add(e, calendar: calendar); return }
        let fp = Self.fingerprint(id)
        let day = AIUsageBook.dayKey(e.date, calendar: calendar)
        if let r = recent[path]?[fp] {
            if e.tokens.total > r.tokens.total {
                book.days[r.day, default: [:]][r.key, default: TokenCounts()] += e.tokens.minus(r.tokens)
                recent[path]?[fp] = (r.day, r.key, e.tokens)
            }
            return
        }
        if fingerprints[day]?.contains(fp) == true { return }
        fingerprints[day, default: []].insert(fp)
        book.add(e, calendar: calendar)
        if recent[path] == nil {
            recentFiles.append(path)
            if recentFiles.count > 16 {
                let old = recentFiles.removeFirst()
                recent[old] = nil
                recentOrder[old] = nil
            }
        }
        recent[path, default: [:]][fp] = (day, AIUsageBook.key(e), e.tokens)
        recentOrder[path, default: []].append(fp)
        if let order = recentOrder[path], order.count > 64 {
            recent[path]?[order[0]] = nil
            recentOrder[path]?.removeFirst()
        }
    }

    private func readDatabases() {
        databasesDirty = false
        for agent in AIAgent.allCases where detected.contains(agent) {
            if let db = AISources.database(agent) { readDatabase(agent, db) }
        }
    }

    /// OpenCode and Kilo keep their history in SQLite: sum it there (read-only) and replace
    /// their share.
    private func readDatabase(_ agent: AIAgent, _ url: URL) {
        let since = Self.date(fromKey: retentionKey(), calendar: calendar).timeIntervalSince1970 * 1000
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let sql = """
            SELECT strftime('%Y-%m-%d', time_created / 1000, 'unixepoch', 'localtime') AS d,
                   json_extract(data, '$.modelID'),
                   sum(json_extract(data, '$.tokens.input')), sum(json_extract(data, '$.tokens.output')),
                   sum(json_extract(data, '$.tokens.reasoning')), sum(json_extract(data, '$.tokens.cache.read')),
                   sum(json_extract(data, '$.tokens.cache.write')), sum(json_extract(data, '$.cost'))
            FROM message
            WHERE time_created >= ? AND json_extract(data, '$.role') = 'assistant'
            GROUP BY 1, 2
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since)
        var entries: [AIUsageEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dayText = sqlite3_column_text(stmt, 0) else { continue }
            let day = String(cString: dayText)
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
            let reasoning = sqlite3_column_int64(stmt, 4)
            let t = TokenCounts(input: sqlite3_column_int64(stmt, 2), output: sqlite3_column_int64(stmt, 3) + reasoning,
                                cacheRead: sqlite3_column_int64(stmt, 5), cacheWrite: sqlite3_column_int64(stmt, 6), reasoning: reasoning)
            let cost = sqlite3_column_double(stmt, 7)
            guard !t.isZero else { continue }
            entries.append(AIUsageEntry(agent: agent, model: model, date: Self.date(fromKey: day, calendar: calendar).addingTimeInterval(12 * 3600),
                                        tokens: t, recordedCost: cost > 0 ? cost : nil))
        }
        book.replace(agent, with: entries, calendar: calendar)
    }

    /// An agent installed while AI usage is on is picked up within five minutes (a few stat
    /// calls each time).
    private func startDetecting() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            let now = AISources.detected()
            guard !now.isSubset(of: self.detected) else { return }
            self.detected = now
            self.stopWatching()
            self.fullScan()   // reads the new agent's history, then publishes
            self.startWatching()
            if self.claudeTimer == nil { self.startClaudePlanChecks() }
        }
        t.resume()
        detectTimer = t
    }

    // MARK: Claude's plan limits (Claude Code's own cache, read locally)

    private func startClaudePlanChecks() {
        guard detected.contains(.claudeCode) else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.readClaudePlan() { self.publish() }
        }
        t.resume()
        claudeTimer = t
    }

    /// One stat a minute; the file is read only when Claude Code has rewritten it.
    @discardableResult
    private func readClaudePlan() -> Bool {
        let url = AISources.claudeJSON
        guard let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              stamp != claudeJSONStamp else { return false }
        claudeJSONStamp = stamp
        guard let data = try? Data(contentsOf: url), let status = ClaudePlanCache.status(fromClaudeJSON: data) else { return false }
        if status == plans[.claudeCode] { return false }
        plans[.claudeCode] = status
        return true
    }

    /// Runs at start and once a day: old days, their fingerprints, and read positions of files
    /// that are gone (agents delete old logs) are dropped, so nothing accumulates over time.
    private func prune() {
        let oldest = retentionKey()
        book.prune(before: oldest)
        fingerprints = fingerprints.filter { $0.key >= oldest }
        files = files.filter { FileManager.default.fileExists(atPath: $0.key) }
    }

    // MARK: Watching

    private func startWatching() {
        let paths = AIAgent.allCases.filter(detected.contains).flatMap(AISources.roots).map(\.path)
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let engine = Unmanaged<AIUsageEngine>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            engine.filesChanged(Array(list.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// Runs on `queue` (the stream's dispatch queue).
    private func filesChanged(_ paths: [String]) {
        guard running else { return }
        for p in paths {
            if p.contains("/.local/share/opencode/opencode.db") || p.contains("/.local/share/kilo/kilo.db") { databasesDirty = true }
            else if let a = agent(of: p), Self.isLog(p, a) { changed.insert(p) }
        }
        guard !scheduled, !changed.isEmpty || databasesDirty else { return }
        scheduled = true
        // Agents write in bursts while working; one read per couple of seconds is plenty.
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            scheduled = false
            guard running else { return }
            let paths = changed
            changed.removeAll()
            for p in paths {
                guard let agent = agent(of: p), FileManager.default.fileExists(atPath: p) else { continue }
                read(agent, URL(fileURLWithPath: p))
            }
            if databasesDirty { readDatabases() }
            if AIUsageBook.dayKey(Date(), calendar: calendar) != lastDay { prune() }
            publish()
            markDirty()
        }
    }

    private var lastDay = ""

    private func agent(of path: String) -> AIAgent? {
        if path.contains("/.claude/projects/") || path.contains("/.config/claude/projects/") { return .claudeCode }
        if path.contains("/.codex/") { return .codex }
        if path.contains("/.gemini/") { return .geminiCLI }
        if path.contains("/.qwen/") { return .qwenCode }
        if path.contains("/.kimi-code/") { return .kimiCode }
        return nil
    }

    // MARK: Publishing & saving

    private func publish(progress: Double? = nil) {
        lastDay = AIUsageBook.dayKey(Date(), calendar: calendar)
        let s = Snapshot(book: book, plans: plans, detected: detected, progress: progress, updated: Date())
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(s) }
    }

    /// Saves at most once a minute while things change (and on stop/quit).
    private func markDirty() {
        if dirtySince == nil {
            dirtySince = Date()
            queue.asyncAfter(deadline: .now() + 60) { [self] in
                guard running, dirtySince != nil else { return }
                save()
            }
        }
    }

    private func save() {
        dirtySince = nil
        var s = Saved()
        s.book = book
        s.files = files
        s.plans = Array(plans.values)
        s.fingerprints = fingerprints.mapValues { set in
            var arr = Array(set)
            return Data(bytes: &arr, count: arr.count * MemoryLayout<UInt64>.size)
        }
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL), let s = try? JSONDecoder().decode(Saved.self, from: data), s.version == 1 else { return }
        book = s.book
        files = s.files
        plans = Dictionary(s.plans.map { ($0.agent, $0) }, uniquingKeysWith: { a, b in a.updated > b.updated ? a : b })
        fingerprints = s.fingerprints.mapValues { data in
            Set(data.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count - 7, by: 8).map { raw.loadUnaligned(fromByteOffset: $0, as: UInt64.self) }
            })
        }
    }

    /// Forgets everything read so far (Settings › Re-read history).
    func reset() {
        queue.async { [self] in
            book = AIUsageBook(); files = [:]; fingerprints = [:]; recent = [:]; recentOrder = [:]; recentFiles = []
            try? FileManager.default.removeItem(at: Self.storeURL)
            if running { fullScan() }
        }
    }

    // MARK: Helpers

    static func date(fromKey key: String, calendar: Calendar) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return Date() }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) ?? Date()
    }

    /// FNV-1a: 8 bytes per message instead of its id strings.
    static func fingerprint(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    static func contains(_ buffer: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        let n = needle.utf8CodeUnitCount
        guard buffer.count >= n, let base = buffer.baseAddress else { return false }
        return memmem(base, buffer.count, needle.utf8Start, n) != nil
    }
}

/// Streams the complete lines of a file from a byte offset; returns the offset after the last
/// complete line (a line still being written is read next time). One reusable buffer, POSIX reads,
/// and lines are handed over in place: nothing is copied.
enum JSONLines {
    static func read(_ url: URL, from offset: UInt64, prefilter: (UnsafeRawBufferPointer) -> Bool,
                     _ body: (UnsafeRawBufferPointer) -> Void) -> UInt64 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return offset }
        defer { close(fd) }
        guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else { return offset }
        // Usually only a few new lines: size the buffer to what was added (4 MB at most; it grows
        // for a longer line).
        var st = stat()
        let pending = fstat(fd, &st) == 0 ? Int(max(0, Int64(st.st_size) - Int64(offset))) : 4 << 20
        var capacity = min(4 << 20, max(64 << 10, pending + 1))
        var buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var filled = 0
        var consumed = offset
        while true {
            if filled == capacity {
                // One line longer than the buffer: grow it.
                let bigger = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 16)
                bigger.copyMemory(from: buffer, byteCount: filled)
                buffer.deallocate()
                buffer = bigger
                capacity *= 2
            }
            let n = Darwin.read(fd, buffer + filled, capacity - filled)
            if n <= 0 { break }
            filled += n
            var start = 0
            // Parsing creates autoreleased objects: drain them per line.
            while start < filled, let nl = memchr(buffer + start, 0x0A, filled - start) {
                let end = buffer.distance(to: nl)
                let line = UnsafeRawBufferPointer(start: buffer + start, count: end - start)
                if line.count > 0, prefilter(line) { autoreleasepool { body(line) } }
                start = end + 1
            }
            consumed += UInt64(start)
            if start > 0 {
                memmove(buffer, buffer + start, filled - start)
                filled -= start
            }
        }
        return consumed
    }
}
