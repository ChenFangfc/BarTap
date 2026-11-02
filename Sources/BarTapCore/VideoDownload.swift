import Foundation

// Pure parts of the video downloader. The engine (yt-dlp) runs as a separate program, see
// VideoDownloads.swift; nothing the user sees names it: it is "the download component".

// MARK: - Choices

/// A resolution (the frame's smaller side, so a vertical 1080×1920 video is 1080p), or audio only.
public enum VideoQuality: Hashable {
    case best
    case height(Int)
    case audio

    /// "best", "1080", "audio"; also the presets BarTap 1.3.0 stored.
    public init?(storage: String) {
        switch storage {
        case "best": self = .best
        case "audio", "mp3": self = .audio
        case "upTo1080": self = .height(1080)
        case "upTo720": self = .height(720)
        default:
            guard let h = Int(storage), (100...10_000).contains(h) else { return nil }
            self = .height(h)
        }
    }

    public var storage: String {
        switch self {
        case .best: return "best"
        case .height(let h): return String(h)
        case .audio: return "audio"
        }
    }

    public var isAudio: Bool { self == .audio }

    /// What can be chosen before a video's own list is known.
    public static let common: [VideoQuality] = [.best, .height(2160), .height(1440), .height(1080), .height(720), .height(480), .audio]

    public var title: String {
        switch self {
        case .best: return L("Best")
        case .height(let h): return "\(h)p"
        case .audio: return L("Audio Only")
        }
    }
}

public enum VideoContainer: String, CaseIterable {
    case mp4, mkv, webm
    public var title: String { self == .webm ? "WebM" : rawValue.uppercased() }
}

public enum AudioFormat: String, CaseIterable {
    case m4a, mp3, opus
    public var title: String { self == .opus ? "Opus" : rawValue.uppercased() }
}

public enum SubtitleMode: String, CaseIterable {
    case off, file, embed
}

public enum SponsorMode: String, CaseIterable {
    case keep, mark, remove
}

public enum AudioQuality: String, CaseIterable {
    case best, k320, k192, k128
    /// `--audio-quality`: 0 is the best variable bit rate.
    public var argument: String {
        switch self {
        case .best: return "0"
        case .k320: return "320K"
        case .k192: return "192K"
        case .k128: return "128K"
        }
    }
    public var kbps: Int { [.best: 245, .k320: 320, .k192: 192, .k128: 128][self]! }
}

public enum FileNameStyle: String, CaseIterable {
    case title, titleID, uploaderTitle, dateTitle

    /// Byte limits keep a name (plus ".f137.mp4.part" while downloading) under macOS's 255 bytes.
    /// A missing uploader or date leaves just the title.
    public var template: String {
        switch self {
        case .title: return "%(title).200B.%(ext)s"
        case .titleID: return "%(title).180B [%(id)s].%(ext)s"
        case .uploaderTitle: return "%(uploader,channel&{:.30} – |)s%(title).130B.%(ext)s"
        case .dateTitle: return "%(upload_date>%Y-%m-%d,release_date>%Y-%m-%d,timestamp>%Y-%m-%d&{} – |)s%(title).180B.%(ext)s"
        }
    }

    public var title: String {
        switch self {
        case .title: return L("Title")
        case .titleID: return L("Title [ID]")
        case .uploaderTitle: return L("Uploader – Title")
        case .dateTitle: return L("Date – Title")
        }
    }
}

/// Browsers whose sign-in the download component can use (`--cookies-from-browser`). Arc is
/// not among them (as of 2026.10.26).
public enum CookieBrowser: String, CaseIterable {
    case safari, chrome, firefox, edge, brave, opera, vivaldi, chromium, whale

    public var title: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Edge"
        case .brave: return "Brave"
        case .opera: return "Opera"
        case .vivaldi: return "Vivaldi"
        case .chromium: return "Chromium"
        case .whale: return "Whale"
        }
    }

    /// To list only installed browsers.
    public var bundleID: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .edge: return "com.microsoft.edgemac"
        case .brave: return "com.brave.Browser"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .chromium: return "org.chromium.Chromium"
        case .whale: return "com.naver.Whale"
        }
    }
}

public enum SpeedLimit {
    /// KB/s; 0 is no limit.
    public static let choices = [0, 500, 1_000, 2_000, 5_000, 10_000]
    public static func argument(_ kb: Int) -> String { kb % 1_000 == 0 ? "\(kb / 1_000)M" : "\(kb)K" }
    public static func title(_ kb: Int) -> String {
        kb <= 0 ? L("No Limit") : kb % 1_000 == 0 ? "\(kb / 1_000) MB/s" : "\(kb) KB/s"
    }
}

/// Choices that carry over from one download to the next. Decoding tolerates missing and
/// unknown values, so an older or newer BarTap's choices never reset the others.
public struct VideoOptions: Equatable, Codable {
    public var container = VideoContainer.mp4
    public var audioFormat = AudioFormat.m4a
    public var subtitles = SubtitleMode.off
    /// A language code, "all", or empty for this Mac's language (plus English).
    public var subtitleLanguage = ""
    public var autoSubtitles = false
    public var embedThumbnail = true
    public var embedMetadata = true
    public var embedChapters = true
    public var sponsors = SponsorMode.keep
    public var browser: CookieBrowser?
    public var speedLimit = 0
    public var fileName = FileNameStyle.title
    public var audioQuality = AudioQuality.best
    public var liveFromStart = false

    public init() {}

    private enum Key: String, CodingKey {
        case container, audioFormat, subtitles, subtitleLanguage, autoSubtitles, embedThumbnail, embedMetadata, embedChapters
        case sponsors, browser, speedLimit, fileName, audioQuality, liveFromStart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func text(_ k: Key) -> String? { try? c.decodeIfPresent(String.self, forKey: k) }
        func flag(_ k: Key, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? d }
        container = text(.container).flatMap(VideoContainer.init(rawValue:)) ?? .mp4
        audioFormat = text(.audioFormat).flatMap(AudioFormat.init(rawValue:)) ?? .m4a
        subtitles = text(.subtitles).flatMap(SubtitleMode.init(rawValue:)) ?? .off
        subtitleLanguage = text(.subtitleLanguage) ?? ""
        autoSubtitles = flag(.autoSubtitles, false)
        embedThumbnail = flag(.embedThumbnail, true)
        embedMetadata = flag(.embedMetadata, true)
        embedChapters = flag(.embedChapters, true)
        sponsors = text(.sponsors).flatMap(SponsorMode.init(rawValue:)) ?? .keep
        browser = text(.browser).flatMap(CookieBrowser.init(rawValue:))
        speedLimit = max(0, (try? c.decodeIfPresent(Int.self, forKey: .speedLimit)) ?? 0)
        fileName = text(.fileName).flatMap(FileNameStyle.init(rawValue:)) ?? .title
        audioQuality = text(.audioQuality).flatMap(AudioQuality.init(rawValue:)) ?? .best
        liveFromStart = flag(.liveFromStart, false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(container.rawValue, forKey: .container)
        try c.encode(audioFormat.rawValue, forKey: .audioFormat)
        try c.encode(subtitles.rawValue, forKey: .subtitles)
        try c.encode(subtitleLanguage, forKey: .subtitleLanguage)
        try c.encode(autoSubtitles, forKey: .autoSubtitles)
        try c.encode(embedThumbnail, forKey: .embedThumbnail)
        try c.encode(embedMetadata, forKey: .embedMetadata)
        try c.encode(embedChapters, forKey: .embedChapters)
        try c.encode(sponsors.rawValue, forKey: .sponsors)
        try c.encodeIfPresent(browser?.rawValue, forKey: .browser)
        try c.encode(speedLimit, forKey: .speedLimit)
        try c.encode(fileName.rawValue, forKey: .fileName)
        try c.encode(audioQuality.rawValue, forKey: .audioQuality)
        try c.encode(liveFromStart, forKey: .liveFromStart)
    }
}

// MARK: - Ranges

public enum PlaylistChoice: Equatable {
    case single         // a video link stays one video, even when it is part of a playlist
    case all
    case items(String)  // normalized by PlaylistItems
}

public enum PlaylistItems {
    /// "1-5, 8, 10-" → "1-5,8,10:" (10- means "10 to the end"); nil if it is not a list of
    /// numbers and ranges.
    public static func normalize(_ text: String) -> String? {
        let parts = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "、", with: ",")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 200 else { return nil }
        var out: [String] = []
        for p in parts {
            let ends = p.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "~", with: "-")
                .split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            switch ends.count {
            case 1:
                guard let n = Int(ends[0]), n >= 1 else { return nil }
                out.append(String(n))
            case 2:
                guard let a = Int(ends[0]), a >= 1 else { return nil }
                if ends[1].isEmpty { out.append("\(a):"); continue }
                guard let b = Int(ends[1]), b >= a else { return nil }
                out.append("\(a)-\(b)")
            default:
                return nil
            }
        }
        return out.joined(separator: ",")
    }
}

/// A part of the video to download, in seconds.
public struct ClipRange: Equatable {
    public var start: Double
    public var end: Double?   // nil: to the end

    public init(start: Double, end: Double?) {
        self.start = start
        self.end = end
    }

    public enum Input: Equatable {
        case none            // both fields empty, or the whole video
        case valid(ClipRange)
        case invalid
    }

    /// The two fields: "1:30", "1:02:03", "90", "1:30.5". An empty start is the beginning, an
    /// empty end (or one past the end) is the end.
    public static func parse(start: String, end: String, duration: Double? = nil) -> Input {
        let s = start.trimmingCharacters(in: .whitespaces), e = end.trimmingCharacters(in: .whitespaces)
        if s.isEmpty && e.isEmpty { return .none }
        guard let from = s.isEmpty ? 0 : seconds(s) else { return .invalid }
        var to: Double?
        if !e.isEmpty {
            guard let v = seconds(e), v > from else { return .invalid }
            to = v
        }
        if let d = duration, d > 0 {
            if from >= d { return .invalid }
            if let t = to, t >= d { to = nil }
        }
        return from == 0 && to == nil ? .none : .valid(ClipRange(start: from, end: to))
    }

    /// "1:30" → 90; "1:02:03.5" → 3723.5; nil for anything else.
    public static func seconds(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "：", with: ":")
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, p) in parts.enumerated() {
            // Digits only, a decimal point only in the seconds; after a colon, under 60.
            let last = i == parts.count - 1
            guard !p.isEmpty, p.allSatisfy({ ("0"..."9").contains($0) || (last && $0 == ".") }),
                  let v = Double(p), i == 0 || v < 60 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// `--download-sections`: "*90-150.5", "*90-inf".
    public var argument: String { "*" + Self.number(start) + "-" + (end.map(Self.number) ?? "inf") }

    private static func number(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

public enum RecentFolders {
    /// Most recent first, without duplicates.
    public static func adding(_ path: String, to list: [String], limit: Int = 5) -> [String] {
        Array(([path] + list.filter { $0 != path }).prefix(limit))
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

/// One download.
public struct VideoRequest: Equatable {
    public var url: String
    public var quality: VideoQuality
    public var folder: String
    public var options: VideoOptions
    public var playlist: PlaylistChoice
    public var clip: ClipRange?

    public init(url: String, quality: VideoQuality, folder: String, options: VideoOptions = VideoOptions(),
                playlist: PlaylistChoice = .single, clip: ClipRange? = nil) {
        self.url = url; self.quality = quality; self.folder = folder; self.options = options
        self.playlist = playlist; self.clip = clip
    }
}

public enum VideoArguments {
    // Machine-readable lines. Everything else the component prints is free text (warnings, errors).
    public static let beginTag = "[bartap-begin] "
    public static let progressTag = "[bartap-progress] "
    public static let stepTag = "[bartap-step] "
    public static let fileTag = "[bartap-file] "
    public static let partsTag = "[bartap-parts] "

    /// Predictable output for everyone: no personal config files, no update checks.
    static let base = ["--ignore-config", "--no-update"]

    /// Same resolution: the container's own codecs first (for MP4, H.264/AAC: plays in QuickTime
    /// and Quick Look), separate streams over a muxed one, the original audio language over dubs.
    static func sort(_ quality: VideoQuality, _ container: VideoContainer) -> String {
        var res = "res"
        if case .height(let h) = quality { res = "res:\(h)" }
        switch container {
        case .mp4: return "lang,\(res),fps,+hasaud,ext:mp4:m4a,vcodec:h264,acodec:aac"
        case .mkv: return "lang,\(res),fps,+hasaud"
        case .webm: return "lang,\(res),fps,+hasaud,ext:webm:webm"
        }
    }

    /// Subtitle languages: the choice, or this Mac's language plus English. Each matches the
    /// language and its regional or original variants (en, en-US, zh-Hans, en-orig), not machine
    /// translations from other languages (en-de), which sites rate-limit.
    static func subtitleLanguages(_ choice: String, preferred: String) -> String {
        if choice == "all" { return "all,-live_chat" }
        let codes = choice.isEmpty ? [preferred, "en"] : [choice]
        var seen: [String] = []
        for c in codes.map({ String($0.split(separator: "-").first ?? "") }) where !c.isEmpty && !seen.contains(c) { seen.append(c) }
        return seen.map { "\($0)(-[A-Z][A-Za-z]+|-orig)?" }.joined(separator: ",")
    }

    static func outputTemplate(_ style: FileNameStyle, playlist: Bool) -> String {
        // A playlist gets its own folder, its videos numbered in playlist order.
        playlist ? "%(playlist_title,playlist|Playlist).100B/%(playlist_index&{:03d} - |)s" + style.template : style.template
    }

    /// `preferredLanguage`: this Mac's first language ("zh-Hans", "en-US"…).
    public static func make(_ r: VideoRequest, tools: VideoToolchain, preferredLanguage: String = "en") -> [String] {
        let o = r.options
        let hasFFmpeg = tools.ffmpeg != nil
        // An unknown version is treated as current; BarTap refuses to run one it can't read.
        let version = tools.version
        // --ignore-errors: a subtitle or cover that fails must not cost the video itself.
        var a = base + ["--newline", "--progress", "--no-mtime", "--ignore-errors"]
        if version?.hasProgressDelta ?? true { a += ["--progress-delta", "0.5"] }
        a += ["--progress-template",
              "download:" + progressTag + "%(progress.{status,downloaded_bytes,total_bytes,total_bytes_estimate,speed,eta,fragment_index,fragment_count})j %(info.format_id)s",
              "--progress-template", "postprocess:" + stepTag + "%(progress.postprocessor)s %(progress.status)s",
              // Printed before subtitles and covers are written, so clean-up knows their names too.
              "--print", "video:" + beginTag + "%(.{id,title,format_id,ext,filesize,filesize_approx,_filename,playlist_index,n_entries})j",
              "--print", "after_move:" + fileTag + "%(filepath)s"]

        switch r.quality {
        case .best, .height:
            if hasFFmpeg {
                a += ["-S", sort(r.quality, o.container), "-f", "bv*+ba/b"]
                switch o.container {
                case .mp4: a += ["--merge-output-format", "mp4", "--remux-video", "mp4"]
                case .mkv: a += ["--merge-output-format", "mkv", "--remux-video", "mkv"]
                case .webm: a += ["--merge-output-format", "webm/mkv"]   // MKV when the codecs don't fit WebM
                }
            } else {
                // The two streams stay apart without ffmpeg; BarTap joins them with AVFoundation,
                // which can only copy H.264 + AAC.
                a += ["-S", sort(r.quality, .mp4), "-f", "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b",
                      "--print", "after_move:" + partsTag + "%(requested_formats.:.filepath)j"]
            }
            if o.subtitles != .off {
                a += ["--write-subs", "--sub-langs", subtitleLanguages(o.subtitleLanguage, preferred: preferredLanguage),
                      "--sub-format", "srt/vtt/best"]
                if o.autoSubtitles { a += ["--write-auto-subs"] }
                if hasFFmpeg {
                    // Embedded subtitles leave no separate file behind (the component keeps it when
                    // --write-subs is given, which generated subtitles need).
                    a += o.subtitles == .embed ? ["--embed-subs", "--compat-options", "no-keep-subs"] : ["--convert-subs", "srt"]
                }
            }
        case .audio:
            if hasFFmpeg {
                // Extraction copies the audio when it already is the format asked for.
                switch o.audioFormat {
                case .m4a: a += ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
                case .mp3: a += ["-f", "ba/b", "-x", "--audio-format", "mp3"]
                case .opus: a += ["-f", "ba[acodec=opus]/ba/b", "-x", "--audio-format", "opus"]
                }
                a += ["--audio-quality", o.audioQuality.argument]
            } else {
                a += ["-f", "ba[ext=m4a]/ba[acodec^=mp4a]/ba"]
            }
        }

        if hasFFmpeg {
            if o.embedMetadata { a += ["--embed-metadata"] }
            // WebM has no cover art; asking for one would turn the file into MKV.
            if o.embedThumbnail && (r.quality.isAudio || o.container != .webm) { a += ["--embed-thumbnail"] }
            if o.embedChapters && !r.quality.isAudio { a += ["--embed-chapters"] }
            switch o.sponsors {
            case .keep: break
            case .mark: a += ["--sponsorblock-mark", "sponsor"]
            case .remove: a += ["--sponsorblock-remove", "sponsor"]
            }
            if let clip = r.clip { a += ["--download-sections", clip.argument, "--force-keyframes-at-cuts"] }
        }
        if let b = o.browser { a += ["--cookies-from-browser", b.rawValue] }
        if o.speedLimit > 0 { a += ["--limit-rate", SpeedLimit.argument(o.speedLimit)] }
        if o.liveFromStart { a += ["--live-from-start"] }

        let isPlaylist: Bool
        switch r.playlist {
        case .single:
            a += ["--no-playlist"]
            isPlaylist = false
        case .all:
            a += ["--yes-playlist"]
            isPlaylist = true
        case .items(let spec):
            a += ["--yes-playlist", "--playlist-items", spec]
            isPlaylist = true
        }
        if let ffmpeg = tools.ffmpeg { a += ["--ffmpeg-location", ffmpeg] }
        a += runtime(tools)
        a += ["-P", r.folder, "-o", outputTemplate(o.fileName, playlist: isPlaylist), "--", r.url]
        return a
    }

    /// The video's details as one JSON document: a playlist lists its entries without
    /// resolving each one, and a video inside a playlist stays a video.
    public static func info(url: String, tools: VideoToolchain, browser: CookieBrowser?) -> [String] {
        var a = base + ["-J", "--flat-playlist", "--no-playlist"]
        if let browser { a += ["--cookies-from-browser", browser.rawValue] }
        return a + runtime(tools) + ["--", url]
    }

    private static func runtime(_ tools: VideoToolchain) -> [String] {
        guard let js = tools.js, tools.version?.hasJSRuntimes ?? true else { return [] }
        return ["--js-runtimes", "\(js.name):\(js.path)"]
    }
}

// MARK: - Video details

/// What one resolution would weigh, per container.
public struct QualityOption: Equatable {
    public var height: Int
    public var highFrameRate: Bool
    public var bytes: [VideoContainer: Int64]

    public init(height: Int, highFrameRate: Bool, bytes: [VideoContainer: Int64]) {
        self.height = height; self.highFrameRate = highFrameRate; self.bytes = bytes
    }

    /// "1080p", "2160p60".
    public var title: String { "\(height)p" + (highFrameRate ? "60" : "") }
}

/// The parts of `-J` the panel shows.
public struct VideoInfo: Equatable {
    public var title: String
    public var uploader: String?
    public var duration: Double?
    public var thumbnail: String?
    public var isLive: Bool
    /// Set for a playlist: how many videos it has.
    public var playlistCount: Int?
    /// Largest first; empty when not known (playlists, single-file links).
    public var qualities: [QualityOption]
    public var audioBytes: [AudioFormat: Int64]
    public var subtitles: [String]
    public var autoSubtitles: [String]

    public var isPlaylist: Bool { playlistCount != nil }

    public init(title: String, uploader: String? = nil, duration: Double? = nil, thumbnail: String? = nil, isLive: Bool = false,
                playlistCount: Int? = nil, qualities: [QualityOption] = [], audioBytes: [AudioFormat: Int64] = [:],
                subtitles: [String] = [], autoSubtitles: [String] = []) {
        self.title = title; self.uploader = uploader; self.duration = duration; self.thumbnail = thumbnail; self.isLive = isLive
        self.playlistCount = playlistCount; self.qualities = qualities; self.audioBytes = audioBytes
        self.subtitles = subtitles; self.autoSubtitles = autoSubtitles
    }

    public static func parse(_ data: Data) -> VideoInfo? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let isPlaylist = (o["_type"] as? String) == "playlist"
        let title = (o["title"] as? String) ?? (o["id"] as? String) ?? ""
        let uploader = [o["uploader"], o["channel"], o["uploader_id"]].compactMap { $0 as? String }.first { !$0.isEmpty }
        var thumbnail = o["thumbnail"] as? String
        if thumbnail == nil, let list = o["thumbnails"] as? [[String: Any]] { thumbnail = list.last?["url"] as? String }
        let entries = o["entries"] as? [Any]
        if isPlaylist, thumbnail == nil, let first = entries?.first as? [String: Any] {
            thumbnail = (first["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
        }
        let duration = Self.double(o["duration"])
        let live = (o["live_status"] as? String) == "is_live" || (o["is_live"] as? Bool) == true
        var info = VideoInfo(title: title, uploader: uploader, duration: duration, thumbnail: thumbnail, isLive: live)
        if isPlaylist {
            info.playlistCount = Self.int(o["playlist_count"]).map(Int.init) ?? entries?.count ?? 0
            return info
        }
        info.subtitles = ((o["subtitles"] as? [String: Any]) ?? [:]).keys.filter { $0 != "live_chat" }.sorted()
        info.autoSubtitles = ((o["automatic_captions"] as? [String: Any]) ?? [:]).keys.sorted()
        let formats = (o["formats"] as? [[String: Any]] ?? []).compactMap { Format($0, duration: duration) }
        info.qualities = qualities(formats)
        info.audioBytes = audioBytes(formats, duration: duration)
        return info
    }

    // MARK: Format list

    struct Format {
        var ext: String
        var vcodec: String?   // nil when the site doesn't say
        var acodec: String?
        var res: Int?
        var fps: Double?
        var bytes: Int64?
        var tbr: Double
        /// HLS/DASH playlists and dynamic-range-compressed audio rank below plain files.
        var streamed: Bool
        var compressed: Bool

        var hasVideo: Bool { vcodec.map { $0 != "none" } ?? (res != nil) }
        var hasAudio: Bool { acodec.map { $0 != "none" } ?? (res == nil) }

        init?(_ f: [String: Any], duration: Double?) {
            ext = f["ext"] as? String ?? ""
            let note = (f["format_note"] as? String ?? "").lowercased()
            // Storyboards (preview tiles) and protected formats can't be downloaded as video.
            if ext == "mhtml" || note.contains("storyboard") || (f["has_drm"] as? Bool) == true { return nil }
            vcodec = f["vcodec"] as? String
            acodec = f["acodec"] as? String
            if vcodec == "none" && acodec == "none" { return nil }
            let w = VideoInfo.int(f["width"]).map(Int.init), h = VideoInfo.int(f["height"]).map(Int.init)
            res = w.flatMap { w in h.map { min(w, $0) } } ?? h
            fps = VideoInfo.double(f["fps"])
            let rate = VideoInfo.double(f["tbr"]) ?? 0
            tbr = rate
            // kbit/s × length when the site gives no size.
            bytes = VideoInfo.int(f["filesize"]) ?? VideoInfo.int(f["filesize_approx"])
                ?? duration.flatMap { d in rate > 0 ? Int64(rate * 1000 / 8 * d) : nil }
            streamed = (f["protocol"] as? String ?? "").contains("m3u8")
            compressed = (f["format_id"] as? String ?? "").hasSuffix("-drc") || note.contains("drc")
        }

        /// The download component's own codec order when nothing else decides: AV1, VP9, H.264.
        var codecRank: Int {
            let c = vcodec ?? ""
            return c.hasPrefix("av01") ? 3 : c.hasPrefix("vp09") || c.hasPrefix("vp9") ? 2 : c.hasPrefix("avc1") ? 1 : 0
        }
    }

    /// Roughly what the download component picks: each preference narrows the pool when it can,
    /// then the highest-ranked format wins.
    static func pick(_ formats: [Format], prefer: [(Format) -> Bool], rank: (Format) -> Double = { $0.tbr }) -> Format? {
        var pool = formats.filter { $0.bytes != nil }
        for p in [{ !$0.compressed }, { !$0.streamed }] + prefer {
            let narrowed = pool.filter(p)
            if !narrowed.isEmpty { pool = narrowed }
        }
        return pool.max { rank($0) < rank($1) }
    }

    static func qualities(_ formats: [Format]) -> [QualityOption] {
        let video = formats.filter { $0.hasVideo && ($0.res ?? 0) > 0 }
        let heights = Set(video.compactMap(\.res)).sorted(by: >)
        let audio = formats.filter { !$0.hasVideo && $0.hasAudio }
        let m4a = pick(audio, prefer: [{ $0.ext == "m4a" }])
        let opus = pick(audio, prefer: [{ $0.acodec?.hasPrefix("opus") == true }])
        return heights.map { h in
            let here = video.filter { $0.res == h }
            var bytes: [VideoContainer: Int64] = [:]
            for c in VideoContainer.allCases {
                let separate: (Format) -> Bool = { !$0.hasAudio }
                let v: Format?
                switch c {
                case .mp4: v = pick(here, prefer: [separate, { $0.ext == "mp4" }, { $0.vcodec?.hasPrefix("avc1") == true }])
                case .mkv: v = pick(here, prefer: [separate], rank: { Double($0.codecRank) * 1e6 + $0.tbr })
                case .webm: v = pick(here, prefer: [separate, { $0.ext == "webm" }])
                }
                guard let v, let vb = v.bytes else { continue }
                let a = v.hasAudio ? nil : (c == .mp4 ? m4a : opus ?? m4a)?.bytes
                bytes[c] = vb + (a ?? 0)
            }
            return QualityOption(height: h, highFrameRate: here.contains { ($0.fps ?? 0) >= 48 }, bytes: bytes)
        }
    }

    static func audioBytes(_ formats: [Format], duration: Double?) -> [AudioFormat: Int64] {
        let audio = formats.filter { !$0.hasVideo && $0.hasAudio }
        var out: [AudioFormat: Int64] = [:]
        out[.m4a] = pick(audio, prefer: [{ $0.ext == "m4a" }])?.bytes
        if let opus = pick(audio, prefer: [{ $0.acodec?.hasPrefix("opus") == true }]), opus.acodec?.hasPrefix("opus") == true { out[.opus] = opus.bytes }
        return out
    }

    /// What an MP3 of this video would weigh at a quality.
    public func mp3Bytes(_ q: AudioQuality) -> Int64? {
        duration.map { Int64($0 * Double(q.kbps) * 1000 / 8) }
    }

    fileprivate static func int(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.int64Value
    }

    fileprivate static func double(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
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
    case file(String)                   // final path, once moved into place
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

    /// An estimate: "~725 KB", "~1.7 GB", "~412 MB".
    public static func approximateSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(max(0, bytes)), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return "~" + (v < 10 && i > 0 ? String(format: "%.1f", v) : String(format: "%.0f", v)) + " " + units[i]
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
    /// A short, readable reason from the component's output (its last ERROR line), without
    /// command-line advice and without naming the component.
    public static func friendly(_ lines: [String], exitCode: Int32) -> String {
        guard var m = lines.last(where: { $0.hasPrefix("ERROR: ") }).map({ String($0.dropFirst(7)) }) else {
            if lines.contains(where: { $0.contains("no such option") }) { return L("The download component is too old. Update it.") }
            return L("The download stopped (code %d).", Int(exitCode))
        }
        let lower = m.lowercased()
        if lower.contains("unsupported url") { return L("This site isn't supported.") }
        if lower.contains("is not a valid url") { return L("That doesn't look like a link to a video.") }
        if lower.contains("requested format is not available") { return L("This quality isn't available. Try Best.") }
        if lower.contains("ffmpeg") && (lower.contains("not found") || lower.contains("not installed")) {
            return L("This needs ffmpeg (brew install ffmpeg).")
        }
        if lower.contains("http error 403") { return L("The site refused the download (HTTP 403). Updating the download component often helps.") }
        if lower.contains("could not copy") && lower.contains("cookie") || lower.contains("operation not permitted") && lower.contains("cookie") {
            return L("Couldn't read the browser's sign-in. Allow access when macOS asks, or pick another browser.")
        }
        if ["nodename nor servname", "failed to resolve", "timed out", "network is unreachable", "no route to host"].contains(where: lower.contains) {
            return L("Couldn't reach the site. Check your connection.")
        }
        // "[youtube] jNQXAC9IVRw: Video unavailable" → "Video unavailable".
        if let r = m.range(of: #"^\[[^\]]+\] ([A-Za-z0-9_-]+: )?"#, options: .regularExpression) { m.removeSubrange(r) }
        for cut in [" (caused by", "; please report", " Use --", " (with --", " See  http", " See http"] {
            if let r = m.range(of: cut) { m = String(m[..<r.lowerBound]) }
        }
        // Sentences that name the component are advice for its own command line.
        let all = m.components(separatedBy: ". ")
        let kept = all.filter { !$0.lowercased().contains("yt-dlp") }
        m = kept.joined(separator: ". ").trimmingCharacters(in: .whitespaces)
        if kept.count < all.count, let last = m.last, !".!?".contains(last) { m += "." }
        if m.isEmpty { return L("The download stopped (code %d).", Int(exitCode)) }
        return m.count > 300 ? String(m.prefix(299)) + "…" : m
    }
}
