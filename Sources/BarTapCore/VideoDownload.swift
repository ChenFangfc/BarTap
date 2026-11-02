import Foundation

// Pure parts of the video downloader (yt-dlp runs as a separate program; see VideoDownloads.swift).

// MARK: - Presets

public enum VideoPreset: String, CaseIterable {
    case best, upTo1080, upTo720, audio, mp3

    /// MP3 always re-encodes, which only ffmpeg can do.
    public var needsFFmpeg: Bool { self == .mp3 }
    public var isAudio: Bool { self == .audio || self == .mp3 }

    public var title: String {
        switch self {
        case .best: return L("Best")
        case .upTo1080: return L("Up to 1080p")
        case .upTo720: return L("Up to 720p")
        case .audio: return L("Audio Only (M4A)")
        case .mp3: return "MP3"
        }
    }
}

// MARK: - Versions

/// yt-dlp versions are release dates: 2026.03.17; nightlies append a build number.
public struct YTDLPVersion: Comparable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int, build: Int
    public let description: String

    public init?(_ raw: String) {
        // `--version` prints the bare version; `-v` shows "stable@2026.03.17 from …".
        guard let token = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { return nil }
        let text = String(token.split(separator: "@").last ?? token)
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3 || parts.count == 4, !parts.contains(nil) else { return nil }
        let n = parts.map { $0! }
        guard (2000...2999).contains(n[0]), (1...12).contains(n[1]), (1...31).contains(n[2]) else { return nil }
        (year, month, day, build) = (n[0], n[1], n[2], n.count == 4 ? n[3] : 0)
        description = text
    }

    public static func < (a: YTDLPVersion, b: YTDLPVersion) -> Bool {
        (a.year, a.month, a.day, a.build) < (b.year, b.month, b.day, b.build)
    }

    public static func == (a: YTDLPVersion, b: YTDLPVersion) -> Bool {
        (a.year, a.month, a.day, a.build) == (b.year, b.month, b.day, b.build)
    }

    public func ageInDays(now: Date = Date()) -> Int? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return cal.dateComponents([.day], from: date, to: now).day
    }

    /// The oldest release whose options BarTap relies on (`--no-update`, `--print WHEN:`).
    public static let minimum = YTDLPVersion("2022.06.22")!
    /// Releases before these reject the option outright, so it is only passed when supported.
    public var hasProgressDelta: Bool { self >= YTDLPVersion("2024.04.09")! }
    public var hasJSRuntimes: Bool { self >= YTDLPVersion("2025.11.12")! }
    /// Sites change often; past this, failures are more likely the tool's age than the link.
    public func isStale(now: Date = Date()) -> Bool { (ageInDays(now: now) ?? 0) > 90 }
}

// MARK: - Tools

public enum ToolSource: String {
    case custom, homebrew, external, managed
}

public struct JSRuntime: Equatable {
    public let name: String
    public let path: String
    public init(name: String, path: String) { self.name = name; self.path = path }

    public var displayName: String {
        switch name {
        case "deno": return "Deno"
        case "node": return "Node.js"
        case "bun": return "Bun"
        default: return name
        }
    }
}

/// What one download runs with.
public struct VideoToolchain: Equatable {
    public var ytdlp: String
    public var version: YTDLPVersion?
    public var ffmpeg: String?
    public var js: JSRuntime?
    public init(ytdlp: String, version: YTDLPVersion?, ffmpeg: String?, js: JSRuntime?) {
        self.ytdlp = ytdlp; self.version = version; self.ffmpeg = ffmpeg; self.js = js
    }
}

/// Where the tools are looked for. Apps opened from Finder get a minimal PATH, so the usual
/// install locations are checked explicitly.
public enum ToolLocator {
    public static let binDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// In order: the user's choice, BarTap's own copy (installed on request, kept up to date),
    /// then an existing install (which may be months old: sites change often).
    public static func ytdlpCandidates(custom: String, home: String, managed: String) -> [(path: String, source: ToolSource)] {
        var list: [(String, ToolSource)] = []
        if !custom.isEmpty { list.append((custom, .custom)) }
        list.append((managed, .managed))
        list += (binDirectories + [home + "/.local/bin"]).map { ($0 + "/yt-dlp", .external) }
        return list
    }

    public static func firstYTDLP(custom: String, home: String, managed: String,
                                  isExecutable: (String) -> Bool) -> (path: String, source: ToolSource)? {
        ytdlpCandidates(custom: custom, home: home, managed: managed).first { isExecutable($0.path) }
    }

    public static func ffmpeg(isExecutable: (String) -> Bool) -> String? {
        binDirectories.map { $0 + "/ffmpeg" }.first(where: isExecutable)
    }

    /// yt-dlp's own preference order (deno, node, bun), including the official installers' folders.
    public static func jsRuntime(home: String, isExecutable: (String) -> Bool) -> JSRuntime? {
        let places: [(String, [String])] = [
            ("deno", binDirectories + [home + "/.deno/bin"]),
            ("node", binDirectories),
            ("bun", binDirectories + [home + "/.bun/bin"]),
        ]
        for (name, dirs) in places {
            if let dir = dirs.first(where: { isExecutable($0 + "/" + name) }) { return JSRuntime(name: name, path: dir + "/" + name) }
        }
        return nil
    }

    /// Homebrew installs are symlinks into its Cellar; `resolved` is the symlink's target.
    public static func source(for path: String, resolved: String) -> ToolSource {
        resolved.contains("/Cellar/") ? .homebrew : .external
    }

    /// PATH for yt-dlp: the install locations first, so it finds ffmpeg/ffprobe and runtimes
    /// even when BarTap itself was launched with launchd's bare PATH.
    public static func searchPath(inherited: String?, includeInstallDirs: Bool = true) -> String {
        var dirs = includeInstallDirs ? binDirectories : []
        for d in (inherited ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        where !d.isEmpty && !dirs.contains(d) && (includeInstallDirs || !binDirectories.contains(d)) {
            dirs.append(d)
        }
        return dirs.joined(separator: ":")
    }
}

// MARK: - Arguments

public struct VideoRequest: Equatable {
    public var url: String
    public var preset: VideoPreset
    public var folder: String
    public var playlists: Bool
    public init(url: String, preset: VideoPreset, folder: String, playlists: Bool) {
        self.url = url; self.preset = preset; self.folder = folder; self.playlists = playlists
    }
}

public enum VideoArguments {
    /// 200 bytes of title keeps names (plus " [id].f123.mp4.part") under macOS's 255-byte limit.
    public static let fileTemplate = "%(title).200B [%(id)s].%(ext)s"

    // Machine-readable lines. Everything else yt-dlp prints is free text (warnings, errors).
    public static let beginTag = "[bartap-begin] "
    public static let progressTag = "[bartap-progress] "
    public static let stepTag = "[bartap-step] "
    public static let fileTag = "[bartap-file] "
    public static let partsTag = "[bartap-parts] "

    /// Same resolution: H.264/AAC in MP4 first (plays in QuickTime and Quick Look), separate
    /// streams over a muxed one (they are better), the original audio language over dubs.
    static func sort(_ preset: VideoPreset) -> String {
        let res: String
        switch preset {
        case .upTo1080: res = "res:1080"
        case .upTo720: res = "res:720"
        default: res = "res"
        }
        return "lang,\(res),fps,+hasaud,ext:mp4:m4a,vcodec:h264,acodec:aac"
    }

    public static func make(_ r: VideoRequest, tools: VideoToolchain) -> [String] {
        let hasFFmpeg = tools.ffmpeg != nil
        // An unknown version is treated as current; BarTap refuses to run one it can't read.
        let version = tools.version
        var a = ["--ignore-config", "--no-update", "--newline", "--progress", "--no-mtime"]
        if version?.hasProgressDelta ?? true { a += ["--progress-delta", "0.5"] }
        a += ["--progress-template",
              "download:" + progressTag + "%(progress.{status,downloaded_bytes,total_bytes,total_bytes_estimate,speed,eta,fragment_index,fragment_count})j %(info.format_id)s",
              "--progress-template", "postprocess:" + stepTag + "%(progress.postprocessor)s %(progress.status)s",
              "--print", "before_dl:" + beginTag + "%(.{id,title,format_id,ext,filesize,filesize_approx,_filename,playlist_index,n_entries})j",
              "--print", "after_move:" + fileTag + "%(filepath)s"]
        switch r.preset {
        case .best, .upTo1080, .upTo720:
            a += ["-S", sort(r.preset)]
            if hasFFmpeg {
                a += ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
            } else {
                // yt-dlp leaves the two streams unmerged without ffmpeg; BarTap joins them with
                // AVFoundation, which can only copy H.264 + AAC.
                a += ["-f", "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b",
                      "--print", "after_move:" + partsTag + "%(requested_formats.:.filepath)j"]
            }
        case .audio:
            // -x without --audio-format only copies the audio out of a video file, never re-encodes.
            a += hasFFmpeg ? ["-f", "ba[ext=m4a]/ba[acodec^=mp4a]/ba/b", "-x"] : ["-f", "ba[ext=m4a]/ba[acodec^=mp4a]/ba"]
        case .mp3:
            a += ["-f", "ba[acodec^=mp3]/ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "2"]
        }
        // --no-playlist only covers "video in a playlist" links; a bare playlist link still
        // downloads everything, so cap it at its first video.
        a += r.playlists ? ["--yes-playlist"] : ["--no-playlist", "--playlist-items", "1"]
        if let ffmpeg = tools.ffmpeg { a += ["--ffmpeg-location", ffmpeg] }
        if let js = tools.js, version?.hasJSRuntimes ?? true { a += ["--js-runtimes", "\(js.name):\(js.path)"] }
        a += ["-P", r.folder, "-o", fileTemplate, "--", r.url]
        return a
    }
}

// MARK: - Output lines

public struct DownloadItem: Equatable {
    public var id: String
    public var title: String
    public var formatID: String
    public var ext: String
    public var approxBytes: Int64?
    public var filename: String
    public var playlistIndex: Int?
    public var playlistCount: Int?

    public init(id: String, title: String, formatID: String, ext: String, approxBytes: Int64?, filename: String,
                playlistIndex: Int? = nil, playlistCount: Int? = nil) {
        self.id = id; self.title = title; self.formatID = formatID; self.ext = ext; self.approxBytes = approxBytes
        self.filename = filename; self.playlistIndex = playlistIndex; self.playlistCount = playlistCount
    }

    /// "137+140" → 2 streams downloaded one after the other.
    public var streamCount: Int { max(1, formatID.split(separator: "+").count) }
}

public struct DownloadProgress: Equatable {
    public var finished: Bool
    public var downloaded: Int64?
    public var total: Int64?
    public var estimate: Int64?
    public var speed: Double?
    public var eta: Double?
    public var fragment: Int?
    public var fragments: Int?
    public var formatID: String

    public init(finished: Bool, downloaded: Int64?, total: Int64?, estimate: Int64? = nil, speed: Double? = nil, eta: Double? = nil,
                fragment: Int? = nil, fragments: Int? = nil, formatID: String) {
        self.finished = finished; self.downloaded = downloaded; self.total = total; self.estimate = estimate
        self.speed = speed; self.eta = eta; self.fragment = fragment; self.fragments = fragments; self.formatID = formatID
    }
}

public enum DownloadEvent: Equatable {
    case begin(DownloadItem)
    case progress(DownloadProgress)
    case step(String, finished: Bool)   // post-processor ("Merger", "ExtractAudio"…)
    case file(String)                   // final path, after yt-dlp moved it into place
    case parts([String])                // unmerged streams (no ffmpeg)
    case error(String)
    case warning(String)
}

public enum DownloadLine {
    public static func parse(_ raw: String) -> DownloadEvent? {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        if let rest = line.dropPrefix(VideoArguments.progressTag) {
            // `{json} <format id>`; the JSON never contains "} " followed by the id.
            guard let close = rest.range(of: "} ", options: .backwards) ?? (rest.hasSuffix("}") ? rest.range(of: "}", options: .backwards) : nil),
                  let o = json(String(rest[..<close.lowerBound]) + "}") else { return nil }
            let format = String(rest[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            return .progress(DownloadProgress(finished: (o["status"] as? String) == "finished",
                                              downloaded: int(o["downloaded_bytes"]), total: int(o["total_bytes"]),
                                              estimate: int(o["total_bytes_estimate"]), speed: double(o["speed"]),
                                              eta: double(o["eta"]), fragment: int(o["fragment_index"]).map(Int.init),
                                              fragments: int(o["fragment_count"]).map(Int.init), formatID: format == "NA" ? "" : format))
        }
        if let rest = line.dropPrefix(VideoArguments.beginTag) {
            guard let o = json(rest), let filename = o["_filename"] as? String else { return nil }
            return .begin(DownloadItem(id: o["id"] as? String ?? "", title: o["title"] as? String ?? "",
                                       formatID: o["format_id"] as? String ?? "", ext: o["ext"] as? String ?? "",
                                       approxBytes: int(o["filesize"]) ?? int(o["filesize_approx"]), filename: filename,
                                       playlistIndex: int(o["playlist_index"]).map(Int.init), playlistCount: int(o["n_entries"]).map(Int.init)))
        }
        if let rest = line.dropPrefix(VideoArguments.stepTag) {
            let words = rest.split(separator: " ")
            guard let name = words.first else { return nil }
            return .step(String(name), finished: words.last == "finished")
        }
        if let rest = line.dropPrefix(VideoArguments.fileTag) {
            return rest.hasPrefix("/") ? .file(rest) : nil
        }
        if let rest = line.dropPrefix(VideoArguments.partsTag) {
            guard let data = rest.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
            let paths = list.compactMap { $0 as? String }.filter { $0.hasPrefix("/") }
            return paths.isEmpty ? nil : .parts(paths)
        }
        if let rest = line.dropPrefix("ERROR: ") { return .error(rest) }
        if let rest = line.dropPrefix("WARNING: ") { return .warning(rest) }
        return nil
    }

    private static func json(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// JSON numbers only; `is Bool` can't tell (an NSNumber 1 also casts to true).
    private static func number(_ v: Any?) -> NSNumber? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    private static func int(_ v: Any?) -> Int64? { number(v)?.int64Value }

    private static func double(_ v: Any?) -> Double? {
        guard let d = number(v)?.doubleValue, d.isFinite else { return nil }
        return d
    }
}

private extension String {
    func dropPrefix(_ p: String) -> String? { hasPrefix(p) ? String(dropFirst(p.count)) : nil }
}

// MARK: - Progress across streams

/// One progress figure for an item whose video and audio arrive as separate downloads.
public struct DownloadMeter: Equatable {
    public private(set) var fraction: Double?   // nil until something is known
    public private(set) var speed: Double?
    public private(set) var eta: Double?
    public private(set) var downloadedBytes: Int64 = 0
    private var expected: Int64?
    private var streams = 1
    private var finishedStreams = 0
    private var finishedBytes: Int64 = 0

    public init() {}

    public mutating func begin(_ item: DownloadItem) {
        self = DownloadMeter()
        expected = item.approxBytes.flatMap { $0 > 0 ? $0 : nil }
        streams = item.streamCount
        fraction = 0
    }

    public mutating func update(_ p: DownloadProgress) {
        if p.finished {
            finishedStreams = min(streams, finishedStreams + 1)
            finishedBytes += p.total ?? p.downloaded ?? 0
            downloadedBytes = finishedBytes
            speed = nil
            eta = nil
            if finishedStreams == streams { fraction = 1 }
            return
        }
        let size = p.total ?? p.estimate
        let done = p.downloaded ?? 0
        downloadedBytes = finishedBytes + done
        var f: Double?
        if let expected, let size, size > 0 {
            // Later streams are still unknown: assume they fill the rest of yt-dlp's estimate.
            let later = finishedStreams + 1 < streams ? max(0, expected - finishedBytes - size) : 0
            let whole = finishedBytes + size + later
            f = Double(finishedBytes + done) / Double(max(whole, 1))
            if let speed = p.speed, speed > 0 { eta = Double(max(0, whole - finishedBytes - done)) / speed } else { eta = p.eta }
        } else {
            let part: Double? = size.flatMap { $0 > 0 ? Double(done) / Double($0) : nil }
                ?? (p.fragments ?? 0 > 0 ? Double(p.fragment ?? 0) / Double(p.fragments!) : nil)
            if let part { f = (Double(finishedStreams) + part) / Double(streams) }
            eta = finishedStreams + 1 < streams ? nil : p.eta
        }
        speed = p.speed
        if let f { fraction = max(fraction ?? 0, min(1, f)) }
    }
}

public enum DownloadText {
    /// "0:12", "4:05", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "42% · 3.1 MB/s · 0:12 left"; "12.3 MB · 3.1 MB/s" while the size is unknown.
    public static func progress(_ m: DownloadMeter) -> String {
        var parts: [String] = []
        if let f = m.fraction, f > 0 || m.downloadedBytes == 0 {
            parts.append(StatFormat.percent(f))
        } else if m.downloadedBytes > 0 {
            parts.append(StatFormat.bytes(UInt64(m.downloadedBytes)))
        }
        if let s = m.speed, s > 0 { parts.append(StatFormat.rate(s)) }
        if let e = m.eta, e.isFinite, e >= 0, (m.fraction ?? 0) < 1 { parts.append(L("%@ left", duration(e))) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Official release

public enum YTDLPRelease {
    /// The macOS build as a folder (universal). The single-file `yt-dlp_macos` unpacks itself on
    /// every launch, and macOS scans the unpacked files each time: ~9 s before each download
    /// (measured), against ~0.3 s for the folder after its first launch.
    public static let asset = "yt-dlp_macos.zip"
    /// The program inside the folder.
    public static let executable = "yt-dlp_macos"
    public static let latestSums = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!

    /// The binary of one release, so it always matches the checksums read from that release.
    public static func assetURL(tag: String?) -> URL {
        URL(string: "https://github.com/yt-dlp/yt-dlp/releases/" + (tag.map { "download/\($0)/" } ?? "latest/download/") + asset)!
    }

    /// "…/releases/download/2026.10.26/SHA2-256SUMS" (where "latest" redirects) → "2026.10.26".
    public static func tag(fromRedirect url: URL) -> String? {
        let c = url.pathComponents
        guard url.host == "github.com", let i = c.firstIndex(of: "download"), i >= 2, c[i - 1] == "releases", i + 1 < c.count,
              c[i + 1] != "latest", YTDLPVersion(c[i + 1]) != nil else { return nil }
        return c[i + 1]
    }
}

// MARK: - Checksums

public enum ChecksumList {
    /// The SHA-256 for `name` in a sha256sum-style list ("<hex>  <name>", or "<hex> *<name>").
    public static func sha256(for name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2 else { continue }
            var file = fields[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            let hex = fields[0].lowercased()
            guard file == name, hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { continue }
            return hex
        }
        return nil
    }
}

// MARK: - Links

public enum LinkDetector {
    private static let pattern = try! NSRegularExpression(pattern: "https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+", options: [.caseInsensitive])

    /// The first http(s) link in copied or pasted text. Share texts wrap links in words
    /// ("看看【标题】https://b23.tv/abc 复制此链接"), so the link is found, not required to be all of it.
    public static func firstWebURL(in text: String) -> String? {
        let head = String(text.prefix(8192))
        let ns = head as NSString
        for m in pattern.matches(in: head, range: NSRange(location: 0, length: ns.length)) {
            var candidate = ns.substring(with: m.range)
            // Sentence punctuation after a link; a ")" only when it closes nothing inside the link.
            while let last = candidate.last {
                if ".,;:!?'\"]}>".contains(last) {
                    candidate.removeLast()
                } else if last == ")" && candidate.filter({ $0 == "(" }).count < candidate.filter({ $0 == ")" }).count {
                    candidate.removeLast()
                } else {
                    break
                }
            }
            guard candidate.count <= 4096, let c = URLComponents(string: candidate),
                  let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = c.host, host.contains(".") || host == "localhost", !host.hasPrefix("."), !host.hasSuffix(".") else { continue }
            return candidate
        }
        return nil
    }
}

// MARK: - Clean-up

public enum DownloadLeftovers {
    /// Files a stopped job leaves behind: whatever it created next to its outputs (same name
    /// stem), except finished files it already reported. Files that existed before the job
    /// started, such as an earlier download of the same video, are never included.
    public static func select(_ files: [(name: String, created: Date)], stems: Set<String>, keep: Set<String>, since: Date) -> [String] {
        files.filter { f in
            !keep.contains(f.name) && f.created >= since.addingTimeInterval(-1)
                && stems.contains { !$0.isEmpty && f.name.hasPrefix($0 + ".") }
        }.map(\.name)
    }

    /// "Title [id].mp4" → "Title [id]".
    public static func stem(of filename: String) -> String {
        let name = (filename as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }
}

// MARK: - Errors

public enum DownloadErrorText {
    /// A short, readable reason from yt-dlp's output (its last ERROR line), without CLI advice.
    public static func friendly(_ lines: [String], exitCode: Int32) -> String {
        guard var m = lines.last(where: { $0.hasPrefix("ERROR: ") }).map({ String($0.dropFirst(7)) }) else {
            if lines.contains(where: { $0.contains("no such option") }) {
                return L("This yt-dlp is too old for BarTap. Update it.")
            }
            return L("yt-dlp stopped (exit code %d).", Int(exitCode))
        }
        let lower = m.lowercased()
        if lower.contains("unsupported url") { return L("This site isn't supported by yt-dlp.") }
        if lower.contains("is not a valid url") { return L("That doesn't look like a link to a video.") }
        if lower.contains("requested format is not available") { return L("No download matches this quality. Try Best.") }
        if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("not installed")) {
            return L("This download needs ffmpeg (brew install ffmpeg).")
        }
        if lower.contains("http error 403") { return L("The site refused the download (HTTP 403). Updating yt-dlp often fixes this.") }
        if ["nodename nor servname", "failed to resolve", "timed out", "network is unreachable", "no route to host"].contains(where: lower.contains) {
            return L("Couldn't reach the site. Check your connection.")
        }
        // "[youtube] jNQXAC9IVRw: Video unavailable" → "Video unavailable".
        if let r = m.range(of: #"^\[[^\]]+\] ([A-Za-z0-9_-]+: )?"#, options: .regularExpression) { m.removeSubrange(r) }
        for cut in [" (caused by", "; please report", " Use --", " (with --", " See  http", " See http"] {
            if let r = m.range(of: cut) { m = String(m[..<r.lowerBound]) }
        }
        m = m.trimmingCharacters(in: .whitespaces)
        return m.count > 300 ? String(m.prefix(299)) + "…" : m
    }
}
