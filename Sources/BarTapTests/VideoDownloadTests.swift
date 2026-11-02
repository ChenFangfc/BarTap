import Foundation
import BarTapCore

// Video downloader: arguments for every option, the component's output, the format list from
// `-J`, ranges, file names, progress, checksums, links, clean-up, errors. Lines and the fixture
// are copied from real yt-dlp runs (2026.03.17 and 2026.10.26).

private func value(_ args: [String], _ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

private func values(_ args: [String], _ flag: String) -> [String] {
    args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
}

/// `-J` for jNQXAC9IVRw ("Me at the zoo"), trimmed to the fields BarTap reads.
private let zooJSON = #"{"id":"jNQXAC9IVRw","title":"Me at the zoo","uploader":"jawed","channel":"jawed","duration":19,"live_status":"not_live","thumbnail":"https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg","subtitles":{"en":[],"de":[]},"automatic_captions":{"en":[],"de":[]},"formats":[{"format_id":"233","ext":"mp4","vcodec":"none","protocol":"m3u8_native","format_note":"Default, low"},{"format_id":"234","ext":"mp4","vcodec":"none","protocol":"m3u8_native","format_note":"Default, high"},{"format_id":"139-drc","ext":"m4a","vcodec":"none","acodec":"mp4a.40.5","filesize":117495,"filesize_approx":117493,"tbr":49.127,"protocol":"https","format_note":"low, DRC"},{"format_id":"249-drc","ext":"webm","vcodec":"none","acodec":"opus","filesize":118912,"filesize_approx":118909,"tbr":50.012,"protocol":"https","format_note":"low, DRC"},{"format_id":"250-drc","ext":"webm","vcodec":"none","acodec":"opus","filesize":151586,"filesize_approx":151585,"tbr":63.755,"protocol":"https","format_note":"low, DRC"},{"format_id":"139","ext":"m4a","vcodec":"none","acodec":"mp4a.40.5","filesize":117526,"filesize_approx":117524,"tbr":49.14,"protocol":"https","format_note":"low"},{"format_id":"249","ext":"webm","vcodec":"none","acodec":"opus","filesize":112596,"filesize_approx":112594,"tbr":47.356,"protocol":"https","format_note":"low"},{"format_id":"250","ext":"webm","vcodec":"none","acodec":"opus","filesize":143795,"filesize_approx":143794,"tbr":60.478,"protocol":"https","format_note":"low"},{"format_id":"140-drc","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":309197,"filesize_approx":309194,"tbr":129.757,"protocol":"https","format_note":"medium, DRC"},{"format_id":"251-drc","ext":"webm","vcodec":"none","acodec":"opus","filesize":255427,"filesize_approx":255425,"tbr":107.429,"protocol":"https","format_note":"medium, DRC"},{"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":309288,"filesize_approx":309287,"tbr":129.796,"protocol":"https","format_note":"medium"},{"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","filesize":252182,"filesize_approx":252180,"tbr":106.064,"protocol":"https","format_note":"medium"},{"format_id":"269","ext":"mp4","vcodec":"avc1.4D400B","acodec":"none","width":192,"height":144,"fps":15.0,"tbr":139.566,"protocol":"m3u8_native"},{"format_id":"160","ext":"mp4","vcodec":"avc1.4D400B","acodec":"none","width":192,"height":144,"fps":15,"filesize":195278,"filesize_approx":195277,"tbr":82.513,"protocol":"https","format_note":"144p"},{"format_id":"602","ext":"mp4","vcodec":"vp09.00.10.08","acodec":"none","width":192,"height":144,"fps":15.0,"tbr":75.112,"protocol":"m3u8_native"},{"format_id":"603","ext":"mp4","vcodec":"vp09.00.11.08.01.05.01.06.00","acodec":"none","width":192,"height":144,"fps":15.0,"tbr":137.995,"protocol":"m3u8_native"},{"format_id":"278","ext":"webm","vcodec":"vp9","acodec":"none","width":192,"height":144,"fps":15,"filesize":185292,"filesize_approx":185290,"tbr":78.293,"protocol":"https","format_note":"144p"},{"format_id":"229","ext":"mp4","vcodec":"avc1.4D400C","acodec":"none","width":320,"height":240,"fps":15.0,"tbr":245.113,"protocol":"m3u8_native"},{"format_id":"230","ext":"mp4","vcodec":"avc1.4D400C","acodec":"none","width":320,"height":240,"fps":15.0,"tbr":294.965,"protocol":"m3u8_native"},{"format_id":"134","ext":"mp4","vcodec":"avc1.4D400C","acodec":"none","width":320,"height":240,"fps":15,"filesize":322379,"filesize_approx":322376,"tbr":136.218,"protocol":"https","format_note":"240p"},{"format_id":"133","ext":"mp4","vcodec":"avc1.4D400C","acodec":"none","width":320,"height":240,"fps":15,"filesize":433081,"filesize_approx":433080,"tbr":182.995,"protocol":"https","format_note":"240p"},{"format_id":"18","ext":"mp4","vcodec":"avc1.42001E","acodec":"mp4a.40.2","width":320,"height":240,"fps":15,"filesize_approx":635110,"tbr":266.531,"protocol":"https","format_note":"240p"},{"format_id":"604","ext":"mp4","vcodec":"vp09.00.20.08.01.05.01.06.00","acodec":"none","width":320,"height":240,"fps":15.0,"tbr":198.586,"protocol":"m3u8_native"},{"format_id":"242","ext":"webm","vcodec":"vp9","acodec":"none","width":320,"height":240,"fps":15,"filesize":293080,"filesize_approx":293078,"tbr":123.838,"protocol":"https","format_note":"240p"},{"format_id":"395","ext":"mp4","vcodec":"av01.0.00M.08.0.110.05.01.06.0","acodec":"none","width":320,"height":240,"fps":15,"filesize":223779,"filesize_approx":223778,"tbr":94.556,"protocol":"https","format_note":"240p"}]}"#

func runVideoDownloadTests() {
    let full = VideoToolchain(ytdlp: "/opt/homebrew/bin/yt-dlp", version: YTDLPVersion("2026.03.17"),
                              ffmpeg: "/opt/homebrew/bin/ffmpeg", js: JSRuntime(name: "deno", path: "/opt/homebrew/bin/deno"))
    var bare = full
    bare.ffmpeg = nil
    bare.js = nil
    let zoo = VideoRequest(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", quality: .best, folder: "/Users/me/Downloads")
    func args(_ edit: (inout VideoRequest) -> Void, tools: VideoToolchain? = nil, language: String = "en") -> [String] {
        var r = zoo
        edit(&r)
        return VideoArguments.make(r, tools: tools ?? full, preferredLanguage: language)
    }

    test("video: Best in MP4 with ffmpeg") {
        let a = args { _ in }
        expect(value(a, "-f") == "bv*+ba/b" && value(a, "-S") == "lang,res,fps,+hasaud,ext:mp4:m4a,vcodec:h264,acodec:aac")
        expect(value(a, "--merge-output-format") == "mp4" && value(a, "--remux-video") == "mp4")
        expect(value(a, "--ffmpeg-location") == "/opt/homebrew/bin/ffmpeg" && value(a, "--js-runtimes") == "deno:/opt/homebrew/bin/deno")
        expect(Array(a.suffix(2)) == ["--", zoo.url], "the link comes last, after --")
        expect(Array(a.prefix(6)) == ["--ignore-config", "--no-update", "--newline", "--progress", "--no-mtime", "--ignore-errors"])
        expect(value(a, "-P") == "/Users/me/Downloads" && value(a, "-o") == "%(title).200B.%(ext)s")
        expect(a.contains("--no-playlist") && !a.contains("--yes-playlist") && !a.contains("--playlist-items"))
        expect(value(a, "--progress-delta") == "0.5" && values(a, "--progress-template").count == 2)
        expect(values(a, "--print").contains("after_move:[bartap-file] %(filepath)s"))
        expect(values(a, "--print").contains { $0.hasPrefix("video:[bartap-begin] ") }, "before subtitles are written")
        expect(a.contains("--embed-metadata") && a.contains("--embed-thumbnail") && a.contains("--embed-chapters"), "the defaults embed everything")
        for absent in ["--write-subs", "--sponsorblock-mark", "--sponsorblock-remove", "--cookies-from-browser", "--limit-rate",
                       "--download-sections", "--live-from-start", "-x"] {
            expect(!a.contains(absent), "off by default: \(absent)")
        }
    }

    test("video: resolutions and containers") {
        expect(value(args { $0.quality = .height(1080) }, "-S")?.hasPrefix("lang,res:1080,") == true)
        let mkv = args { $0.options.container = .mkv; $0.quality = .height(720) }
        expect(value(mkv, "-S") == "lang,res:720,fps,+hasaud" && value(mkv, "--merge-output-format") == "mkv" && value(mkv, "--remux-video") == "mkv")
        let webm = args { $0.options.container = .webm }
        expect(value(webm, "-S") == "lang,res,fps,+hasaud,ext:webm:webm" && value(webm, "--merge-output-format") == "webm/mkv")
        expect(!webm.contains("--remux-video") && !webm.contains("--embed-thumbnail"), "WebM has no cover art (it would turn into MKV)")
    }

    test("video: without ffmpeg, H.264 + M4A for AVFoundation, no extras") {
        let a = args({ $0.options.container = .mkv; $0.options.sponsors = .remove; $0.options.subtitles = .embed
                       $0.clip = ClipRange(start: 5, end: 10) }, tools: bare)
        expect(value(a, "-f") == "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b", "MP4 whatever the container choice")
        expect(values(a, "--print").contains("after_move:[bartap-parts] %(requested_formats.:.filepath)j"))
        for absent in ["--merge-output-format", "--ffmpeg-location", "--js-runtimes", "--embed-metadata", "--embed-thumbnail",
                       "--embed-subs", "--convert-subs", "--sponsorblock-remove", "--download-sections"] {
            expect(!a.contains(absent), "needs ffmpeg: \(absent)")
        }
        expect(a.contains("--write-subs"), "subtitles still come as a file")
    }

    test("video: audio formats and quality") {
        let m4a = args { $0.quality = .audio }
        expect(value(m4a, "-f") == "ba[ext=m4a]/ba/b" && m4a.contains("-x") && value(m4a, "--audio-format") == "m4a" && value(m4a, "--audio-quality") == "0")
        expect(!m4a.contains("--embed-chapters") && !m4a.contains("--write-subs") && !m4a.contains("--merge-output-format"))
        expect(m4a.contains("--embed-thumbnail") && m4a.contains("--embed-metadata"), "cover art and tags for music")
        let mp3 = args { $0.quality = .audio; $0.options.audioFormat = .mp3; $0.options.audioQuality = .k192 }
        expect(value(mp3, "-f") == "ba/b" && value(mp3, "--audio-format") == "mp3" && value(mp3, "--audio-quality") == "192K")
        let opus = args { $0.quality = .audio; $0.options.audioFormat = .opus; $0.options.audioQuality = .k320 }
        expect(value(opus, "-f") == "ba[acodec=opus]/ba/b" && value(opus, "--audio-format") == "opus" && value(opus, "--audio-quality") == "320K")
        let bareAudio = args({ $0.quality = .audio; $0.options.audioFormat = .mp3 }, tools: bare)
        expect(value(bareAudio, "-f") == "ba[ext=m4a]/ba[acodec^=mp4a]/ba" && !bareAudio.contains("-x"))
        expect(AudioQuality.allCases.map(\.argument) == ["0", "320K", "192K", "128K"])
    }

    test("video: subtitles") {
        let file = args({ $0.options.subtitles = .file }, language: "zh-Hans")
        expect(file.contains("--write-subs") && value(file, "--sub-format") == "srt/vtt/best")
        expect(value(file, "--sub-langs") == "zh(-[A-Z][A-Za-z]+|-orig)?,en(-[A-Z][A-Za-z]+|-orig)?", "\(value(file, "--sub-langs") ?? "-")")
        expect(value(file, "--convert-subs") == "srt" && !file.contains("--embed-subs") && !file.contains("--write-auto-subs"))
        let embed = args { $0.options.subtitles = .embed; $0.options.autoSubtitles = true; $0.options.subtitleLanguage = "de" }
        expect(embed.contains("--embed-subs") && embed.contains("--write-auto-subs") && value(embed, "--sub-langs") == "de(-[A-Z][A-Za-z]+|-orig)?")
        expect(value(embed, "--compat-options") == "no-keep-subs", "no separate file next to the video")
        expect(!embed.contains("--convert-subs"))
        expect(value(args { $0.options.subtitles = .file; $0.options.subtitleLanguage = "all" }, "--sub-langs") == "all,-live_chat")
        expect(value(args({ $0.options.subtitles = .file }, language: "en-US"), "--sub-langs") == "en(-[A-Z][A-Za-z]+|-orig)?", "no duplicate English")
        // The pattern the component full-matches: variants yes, translations from other languages no.
        let pattern = try! NSRegularExpression(pattern: "^(?:zh(-[A-Z][A-Za-z]+|-orig)?)$")
        func matches(_ s: String) -> Bool { pattern.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil }
        expect(["zh", "zh-Hans", "zh-Hant", "zh-CN", "zh-orig"].allSatisfy(matches) && !["zh-Hans-en", "zh-en", "zhx"].contains(where: matches))
        // The component splits the list on commas: each piece must be a whole pattern.
        let pieces = (value(file, "--sub-langs") ?? "").split(separator: ",").map(String.init)
        expect(pieces.count == 2 && pieces.allSatisfy { (try? NSRegularExpression(pattern: $0)) != nil }, "\(pieces)")
    }

    test("video: extras, sign-in, speed, live") {
        let a = args { o in
            o.options.sponsors = .remove; o.options.browser = .chrome; o.options.speedLimit = 500; o.options.liveFromStart = true
            o.options.embedMetadata = false; o.options.embedThumbnail = false; o.options.embedChapters = false
        }
        expect(value(a, "--sponsorblock-remove") == "sponsor" && value(a, "--cookies-from-browser") == "chrome")
        expect(value(a, "--limit-rate") == "500K" && a.contains("--live-from-start"))
        expect(!a.contains("--embed-metadata") && !a.contains("--embed-thumbnail") && !a.contains("--embed-chapters"))
        expect(value(args { $0.options.sponsors = .mark }, "--sponsorblock-mark") == "sponsor")
        expect(SpeedLimit.argument(2_000) == "2M" && SpeedLimit.argument(500) == "500K" && SpeedLimit.choices.first == 0)
        expect(CookieBrowser.allCases.map(\.rawValue) == ["safari", "chrome", "firefox", "edge", "brave", "opera", "vivaldi", "chromium", "whale"],
               "the browsers the component supports (no Arc)")
    }

    test("video: playlists and parts") {
        let all = args { $0.playlist = .all }
        expect(all.contains("--yes-playlist") && !all.contains("--no-playlist"))
        expect(value(all, "-o") == "%(playlist_title,playlist|Playlist).100B/%(playlist_index&{:03d} - |)s%(title).200B.%(ext)s",
               "a playlist gets its own folder, numbered")
        let items = args { $0.playlist = .items("1-5,8,10:") }
        expect(items.contains("--yes-playlist") && value(items, "--playlist-items") == "1-5,8,10:")
        let clip = args { $0.clip = ClipRange(start: 5, end: 10) }
        expect(value(clip, "--download-sections") == "*5-10" && clip.contains("--force-keyframes-at-cuts"))
    }

    test("video: file name styles") {
        expect(FileNameStyle.title.template == "%(title).200B.%(ext)s")
        expect(FileNameStyle.titleID.template == "%(title).180B [%(id)s].%(ext)s")
        expect(FileNameStyle.uploaderTitle.template == "%(uploader,channel&{:.30} – |)s%(title).130B.%(ext)s", "no uploader: just the title")
        expect(FileNameStyle.dateTitle.template == "%(upload_date>%Y-%m-%d,release_date>%Y-%m-%d,timestamp>%Y-%m-%d&{} – |)s%(title).180B.%(ext)s")
        for style in FileNameStyle.allCases { expect(value(args { $0.options.fileName = style }, "-o") == style.template) }
    }

    test("video: details request") {
        let a = VideoArguments.info(url: zoo.url, tools: full, browser: .safari)
        expect(a == ["--ignore-config", "--no-update", "-J", "--flat-playlist", "--no-playlist", "--cookies-from-browser", "safari",
                     "--js-runtimes", "deno:/opt/homebrew/bin/deno", "--", zoo.url], "\(a)")
        expect(VideoArguments.info(url: zoo.url, tools: bare, browser: nil) == ["--ignore-config", "--no-update", "-J", "--flat-playlist", "--no-playlist", "--", zoo.url])
    }

    test("video: format list from -J") {
        guard let info = VideoInfo.parse(Data(zooJSON.utf8)) else { expect(false, "parse"); return }
        expect(info.title == "Me at the zoo" && info.uploader == "jawed" && info.duration == 19 && !info.isLive && !info.isPlaylist)
        expect(info.thumbnail == "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg")
        expect(info.qualities.map(\.height) == [240, 144] && info.qualities.allSatisfy { !$0.highFrameRate }, "\(info.qualities.map(\.title))")
        // What the component itself picks: 133+140 (MP4), 395+251 (MKV), 242+251 (WebM), 160+140 (144p MP4).
        let q240 = info.qualities[0], q144 = info.qualities[1]
        expect(q240.bytes[.mp4] == 433_081 + 309_288, "\(q240.bytes[.mp4] ?? -1)")
        expect(q240.bytes[.mkv] == 223_779 + 252_182, "\(q240.bytes[.mkv] ?? -1)")
        expect(q240.bytes[.webm] == 293_080 + 252_182, "\(q240.bytes[.webm] ?? -1)")
        expect(q144.bytes[.mp4] == 195_278 + 309_288, "\(q144.bytes[.mp4] ?? -1)")
        expect(info.audioBytes[.m4a] == 309_288 && info.audioBytes[.opus] == 252_182, "\(info.audioBytes)")
        expect(info.mp3Bytes(.k128) == 19 * 128_000 / 8)
        expect(info.subtitles == ["de", "en"] && info.autoSubtitles == ["de", "en"])
        expect(q240.title == "240p" && QualityOption(height: 1080, highFrameRate: true, bytes: [:]).title == "1080p60")
    }

    test("video: playlists, live streams, vertical video in -J") {
        let playlist = #"{"_type":"playlist","title":"Lectures","playlist_count":12,"entries":[{"id":"a","title":"One","thumbnails":[{"url":"https://x/1.jpg"}]}]}"#
        guard let p = VideoInfo.parse(Data(playlist.utf8)) else { expect(false, "playlist"); return }
        expect(p.isPlaylist && p.playlistCount == 12 && p.title == "Lectures" && p.thumbnail == "https://x/1.jpg" && p.qualities.isEmpty)
        let noCount = #"{"_type":"playlist","title":"L","entries":[{"id":"a"},{"id":"b"},{"id":"c"}]}"#
        expect(VideoInfo.parse(Data(noCount.utf8))?.playlistCount == 3)
        let live = #"{"title":"Live!","channel":"Station","live_status":"is_live","formats":[{"ext":"mp4","vcodec":"avc1","acodec":"mp4a","width":1280,"height":720,"tbr":3000,"protocol":"m3u8_native"}]}"#
        guard let l = VideoInfo.parse(Data(live.utf8)) else { expect(false, "live"); return }
        expect(l.isLive && l.uploader == "Station" && l.qualities.map(\.height) == [720] && l.qualities[0].bytes.isEmpty, "no length, no size")
        let vertical = #"{"title":"Short","duration":10,"formats":[{"ext":"mp4","vcodec":"avc1","acodec":"none","width":1080,"height":1920,"fps":60,"filesize":5000000},{"ext":"mhtml","vcodec":"none","acodec":"none","format_note":"storyboard"},{"ext":"m4a","vcodec":"none","acodec":"mp4a","filesize":100000,"tbr":128}]}"#
        guard let v = VideoInfo.parse(Data(vertical.utf8)) else { expect(false, "vertical"); return }
        expect(v.qualities.map(\.title) == ["1080p60"] && v.qualities[0].bytes[.mp4] == 5_100_000, "the smaller side is the resolution")
        expect(VideoInfo.parse(Data("not json".utf8)) == nil)
    }

    test("video: time ranges") {
        for (text, want) in [("90", 90.0), ("1:30", 90), ("01:02:03", 3723), ("1:30.5", 90.5), ("1：30", 90), (" 5 ", 5)] as [(String, Double)] {
            expect(ClipRange.seconds(text) == want, "\(text) → \(ClipRange.seconds(text) ?? -1)")
        }
        for bad in ["", "1:75", "abc", "-5", "1:2:3:4", "1.5:30", "1:", ":30"] { expect(ClipRange.seconds(bad) == nil, bad) }
        expect(ClipRange.parse(start: "", end: "") == .none)
        expect(ClipRange.parse(start: "0:05", end: "0:10") == .valid(ClipRange(start: 5, end: 10)))
        expect(ClipRange.parse(start: "1:00", end: "") == .valid(ClipRange(start: 60, end: nil)))
        expect(ClipRange.parse(start: "", end: "10") == .valid(ClipRange(start: 0, end: 10)))
        expect(ClipRange.parse(start: "10", end: "5") == .invalid && ClipRange.parse(start: "x", end: "") == .invalid)
        expect(ClipRange.parse(start: "5", end: "30", duration: 19) == .valid(ClipRange(start: 5, end: nil)), "past the end is the end")
        expect(ClipRange.parse(start: "20", end: "", duration: 19) == .invalid && ClipRange.parse(start: "0", end: "19", duration: 19) == .none)
        expect(ClipRange(start: 5, end: 10).argument == "*5-10" && ClipRange(start: 60, end: nil).argument == "*60-inf")
        expect(ClipRange(start: 1.5, end: 2.25).argument == "*1.5-2.25")
    }

    test("video: playlist items") {
        let cases: [(String, String?)] = [("1-5, 8, 10-", "1-5,8,10:"), ("3", "3"), ("1，2、3", "1,2,3"), ("1–4", "1-4"), ("2 - 6", "2-6"),
                                          ("5-3", nil), ("0", nil), ("a", nil), ("", nil), ("1-2-3", nil), (" , ", nil)]
        for (text, want) in cases { expect(PlaylistItems.normalize(text) == want, "\(text) → \(PlaylistItems.normalize(text) ?? "nil")") }
    }

    test("video: choices that carry over") {
        var o = VideoOptions()
        o.container = .webm; o.subtitles = .embed; o.browser = .firefox; o.speedLimit = 2_000; o.fileName = .dateTitle
        let data = try? JSONEncoder().encode(o)
        expect(data.flatMap { try? JSONDecoder().decode(VideoOptions.self, from: $0) } == o, "round trip")
        let partial = try? JSONDecoder().decode(VideoOptions.self, from: Data(#"{"container":"mkv","browser":"arc","fileName":"nope","speedLimit":-5}"#.utf8))
        expect(partial?.container == .mkv && partial?.browser == nil && partial?.fileName == .title && partial?.speedLimit == 0 && partial?.embedChapters == true,
               "missing or unknown values fall back to the defaults")
        expect(VideoQuality(storage: "best") == .best && VideoQuality(storage: "1080") == .height(1080) && VideoQuality(storage: "audio") == .audio)
        expect(VideoQuality(storage: "upTo720") == .height(720) && VideoQuality(storage: "mp3") == .audio && VideoQuality(storage: "huh") == nil, "1.3.0 presets")
        expect(VideoQuality.height(1440).storage == "1440")
        expect(RecentFolders.adding("/b", to: ["/a", "/b", "/c"]) == ["/b", "/a", "/c"])
        expect(RecentFolders.adding("/x", to: ["/1", "/2", "/3", "/4", "/5"]) == ["/x", "/1", "/2", "/3", "/4"])
    }

    test("video: version strings") {
        guard let v = YTDLPVersion("2026.03.17\n") else { expect(false, "parse"); return }
        expect(v.year == 2026 && v.month == 3 && v.day == 17 && v.build == 0 && v.description == "2026.03.17")
        expect(YTDLPVersion("stable@2026.03.17 from yt-dlp/yt-dlp [04d6974f5] (pip)") == v)
        expect(YTDLPVersion("2026.03.20.232604")! > YTDLPVersion("2026.03.20")!, "nightly builds sort after the day's release")
        expect(YTDLPVersion("2026.03.17")! < YTDLPVersion("2026.10.26")!)
        for bad in ["", "yt-dlp", "2026.13.01", "1.2.3", "2026.03", "2026.03.17.x"] { expect(YTDLPVersion(bad) == nil, bad) }
        expect(YTDLPVersion("2025.11.12")!.hasJSRuntimes && !YTDLPVersion("2025.10.22")!.hasJSRuntimes)
        expect(YTDLPVersion("2024.04.09")!.hasProgressDelta && !YTDLPVersion("2024.03.10")!.hasProgressDelta)
        expect(YTDLPVersion("2022.05.18")! < YTDLPVersion.minimum)
        let now = ISO8601DateFormatter().date(from: "2026-11-02T08:00:00Z")!
        expect(v.ageInDays(now: now) == 230, "\(v.ageInDays(now: now) ?? -1)")
        expect(v.isStale(now: now) && !YTDLPVersion("2026.10.26")!.isStale(now: now))
    }

    test("video: the component's output lines") {
        let begin = #"[bartap-begin] {"id": "jNQXAC9IVRw", "title": "Me at the zoo", "format_id": "133+140", "ext": "mp4", "filesize_approx": 742369, "_filename": "/x/Me at the zoo [jNQXAC9IVRw].mp4", "playlist_index": null}"#
        guard case .begin(let item)? = DownloadLine.parse(begin) else { expect(false, "begin"); return }
        expect(item.id == "jNQXAC9IVRw" && item.title == "Me at the zoo" && item.formatID == "133+140" && item.streamCount == 2)
        expect(item.approxBytes == 742369 && item.filename == "/x/Me at the zoo [jNQXAC9IVRw].mp4" && item.playlistIndex == nil)
        let unicode = #"[bartap-begin] {"id": "BV1", "title": "【官方 MV】\"Quote\" — 中文", "format_id": "30080+30280", "ext": "mp4", "filesize": 10, "filesize_approx": 99, "_filename": "/x/a.mp4", "playlist_index": 2, "n_entries": 15}"#
        guard case .begin(let u)? = DownloadLine.parse(unicode) else { expect(false, "unicode begin"); return }
        expect(u.title == "【官方 MV】\"Quote\" — 中文" && u.approxBytes == 10 && u.playlistIndex == 2 && u.playlistCount == 15)

        let p = DownloadLine.parse(#"[bartap-progress] {"status": "downloading", "downloaded_bytes": 1024, "total_bytes": 433081} 133"#)
        expect(p == .progress(DownloadProgress(finished: false, downloaded: 1024, total: 433081, formatID: "133")), "\(String(describing: p))")
        let f = DownloadLine.parse(#"[bartap-progress] {"status": "finished", "downloaded_bytes": 433081, "total_bytes": 433081, "speed": 6063258.321035292} 133"#)
        expect(f == .progress(DownloadProgress(finished: true, downloaded: 433081, total: 433081, speed: 6063258.321035292, formatID: "133")))
        let hls = DownloadLine.parse(#"[bartap-progress] {"status": "downloading", "downloaded_bytes": 5, "total_bytes_estimate": 100.5, "eta": 7, "fragment_index": 1, "fragment_count": 20} NA"#)
        expect(hls == .progress(DownloadProgress(finished: false, downloaded: 5, total: nil, estimate: 100, eta: 7, fragment: 1, fragments: 20, formatID: "")), "\(String(describing: hls))")

        expect(DownloadLine.parse("[bartap-step] Merger started") == .step("Merger", finished: false))
        expect(DownloadLine.parse("[bartap-step] Merger finished") == .step("Merger", finished: true))
        expect(DownloadLine.parse("[bartap-file] /x/Me at the zoo [jNQXAC9IVRw].mp4") == .file("/x/Me at the zoo [jNQXAC9IVRw].mp4"))
        expect(DownloadLine.parse(#"[bartap-parts] ["/x/a.f133.mp4", "/x/a.f140.m4a"]"#) == .parts(["/x/a.f133.mp4", "/x/a.f140.m4a"]))
        expect(DownloadLine.parse("[bartap-parts] NA") == nil && DownloadLine.parse("[bartap-file] NA") == nil)
        expect(DownloadLine.parse("ERROR: [youtube] x: Video unavailable\r") == .error("[youtube] x: Video unavailable"))
        expect(DownloadLine.parse("WARNING: jNQXAC9IVRw: writing DASH m4a. Only some players support this container.")
               == .warning("jNQXAC9IVRw: writing DASH m4a. Only some players support this container."))
        for noise in ["", "[download] 100% of 1.00MiB", "[bartap-progress] not json 133", "[bartap-begin] {}"] {
            expect(DownloadLine.parse(noise) == nil, noise)
        }
    }

    test("video: one progress figure across separate video and audio downloads") {
        var m = DownloadMeter()
        expect(m.fraction == nil)
        m.begin(DownloadItem(id: "z", title: "", formatID: "133+140", ext: "mp4", approxBytes: 742_369, filename: "/x/z.mp4"))
        expect(m.fraction == 0)
        m.update(DownloadProgress(finished: false, downloaded: 216_540, total: 433_081, speed: 1_000_000, formatID: "133"))
        expect(abs((m.fraction ?? 0) - 216_540.0 / 742_369) < 1e-6, "video half way: \(m.fraction ?? -1)")
        expect(abs((m.eta ?? 0) - (742_369.0 - 216_540) / 1_000_000) < 1e-6, "eta covers the audio still to come")
        m.update(DownloadProgress(finished: false, downloaded: 1_000, total: 433_081, formatID: "133"))
        expect(abs((m.fraction ?? 0) - 216_540.0 / 742_369) < 1e-6, "never goes backwards")
        m.update(DownloadProgress(finished: true, downloaded: 433_081, total: 433_081, formatID: "133"))
        m.update(DownloadProgress(finished: false, downloaded: 154_644, total: 309_288, speed: 2e6, formatID: "140"))
        expect(abs((m.fraction ?? 0) - (433_081.0 + 154_644) / 742_369) < 1e-6, "\(m.fraction ?? -1)")
        expect(m.downloadedBytes == 433_081 + 154_644)
        m.update(DownloadProgress(finished: true, downloaded: 309_288, total: 309_288, formatID: "140"))
        expect(m.fraction == 1 && m.eta == nil)

        var hls = DownloadMeter()
        hls.begin(DownloadItem(id: "h", title: "", formatID: "hls-720p+audio", ext: "mp4", approxBytes: nil, filename: "/x/h.mp4"))
        hls.update(DownloadProgress(finished: false, downloaded: 10, total: nil, fragment: 5, fragments: 10, formatID: "hls-720p"))
        expect(hls.fraction == 0.25, "no sizes: fragments, per stream: \(hls.fraction ?? -1)")
    }

    test("video: status text") {
        let saved = Loc.language
        Loc.language = .en
        defer { Loc.language = saved }
        var m = DownloadMeter()
        m.begin(DownloadItem(id: "b", title: "", formatID: "137", ext: "mp4", approxBytes: 100_000_000, filename: "/x/b.mp4"))
        m.update(DownloadProgress(finished: false, downloaded: 42_000_000, total: 100_000_000, speed: 3_250_000, formatID: "137"))
        expect(DownloadText.progress(m) == "42% · 3.1 MB/s · 0:18 left", DownloadText.progress(m))
        var unknown = DownloadMeter()
        unknown.begin(DownloadItem(id: "u", title: "", formatID: "0", ext: "mp4", approxBytes: nil, filename: "/x/u.mp4"))
        unknown.update(DownloadProgress(finished: false, downloaded: 12_900_000, total: nil, speed: 2_000_000, formatID: "0"))
        expect(DownloadText.progress(unknown) == "12.3 MB · 1.9 MB/s", DownloadText.progress(unknown))
        expect(DownloadText.duration(0) == "0:00" && DownloadText.duration(12) == "0:12" && DownloadText.duration(245) == "4:05")
        expect(DownloadText.duration(3723) == "1:02:03")
        expect(VideoQuality.best.title == "Best" && VideoQuality.audio.title == "Audio Only" && VideoQuality.height(720).title == "720p")
        expect(SpeedLimit.title(0) == "No Limit" && SpeedLimit.title(1_000) == "1 MB/s" && SpeedLimit.title(500) == "500 KB/s")
        expect(DownloadText.approximateSize(742_369) == "~725 KB" && DownloadText.approximateSize(1_820_000_000) == "~1.7 GB")
        expect(DownloadText.approximateSize(412_000_000) == "~393 MB" && DownloadText.approximateSize(5_000) == "~4.9 KB")
    }

    test("video: checksum list") {
        let sums = """
        e51e69e89489f199530f13d32a4342da3ddb2cf34842f364603a066db05afbf3  yt-dlp
        20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1  yt-dlp_macos.zip
        0F922C15CCC0B83EEFA1C8BC9104E434318C4BF16E408E1EE93B7745A6EFE0AA  yt-dlp_macos
        c0407c66361f50a99e10949ae882ea2ad7de9086b75d226d8fd88da4f74828fa *yt-dlp_x86.exe
        abc  yt-dlp_short
        """
        expect(ChecksumList.sha256(for: "yt-dlp_macos", in: sums) == "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa")
        expect(ChecksumList.sha256(for: YTDLPRelease.asset, in: sums) == "20d98fa608998eff87d1d35a6e9fb65e4b874639a6cc89addc19da3becde3ef1")
        expect(ChecksumList.sha256(for: "yt-dlp_x86.exe", in: sums) == "c0407c66361f50a99e10949ae882ea2ad7de9086b75d226d8fd88da4f74828fa")
        expect(ChecksumList.sha256(for: "yt-dlp_short", in: sums) == nil, "not a SHA-256")
        expect(ChecksumList.sha256(for: "yt-dlp_linux", in: sums) == nil)
        expect(ChecksumList.sha256(for: "yt-dlp_macos", in: "") == nil)
    }

    test("video: official release URLs") {
        expect(YTDLPRelease.tag(fromRedirect: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/SHA2-256SUMS")!) == "2026.10.26")
        expect(YTDLPRelease.tag(fromRedirect: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/307260205/5f32")!) == nil)
        expect(YTDLPRelease.tag(fromRedirect: URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS")!) == nil)
        expect(YTDLPRelease.assetURL(tag: "2026.10.26").absoluteString == "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos.zip")
        expect(YTDLPRelease.assetURL(tag: nil).absoluteString == "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos.zip")
    }

    test("video: links in copied text") {
        let cases: [(String, String?)] = [
            ("https://www.youtube.com/watch?v=jNQXAC9IVRw", "https://www.youtube.com/watch?v=jNQXAC9IVRw"),
            ("  https://youtu.be/jNQXAC9IVRw\n", "https://youtu.be/jNQXAC9IVRw"),
            ("【标题】看看https://b23.tv/AbCdEf 复制此链接", "https://b23.tv/AbCdEf"),
            ("Watch this: https://vimeo.com/76979871.", "https://vimeo.com/76979871"),
            ("(see https://en.wikipedia.org/wiki/Foo_(bar))", "https://en.wikipedia.org/wiki/Foo_(bar)"),
            ("HTTPS://Example.com/Video", "HTTPS://Example.com/Video"),
            ("a https://a.com/1 b https://b.com/2", "https://a.com/1"),
            ("ftp://example.com/x", nil), ("javascript:alert(1)", nil), ("file:///etc/passwd", nil),
            ("www.youtube.com/watch?v=x", nil), ("https://", nil), ("https://nodot/x", nil), ("just words", nil),
            (String(repeating: "x", count: 100_000) + " https://late.example.com", nil),
        ]
        for (text, want) in cases {
            let got = LinkDetector.firstWebURL(in: text)
            expect(got == want, "\(text.prefix(60)) → \(got ?? "nil")")
        }
    }

    test("video: leftovers of a stopped job") {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let stem = "Me at the zoo [jNQXAC9IVRw]"
        let files: [(name: String, created: Date)] = [
            ("\(stem).f133.mp4", t0.addingTimeInterval(1)),
            ("\(stem).f140.m4a.part", t0.addingTimeInterval(2)),
            ("\(stem).f140.m4a.ytdl", t0.addingTimeInterval(2)),
            ("\(stem).temp.mp4", t0.addingTimeInterval(3)),
            ("\(stem).mp4", t0.addingTimeInterval(-100)),         // an earlier download of the same video
            ("\(stem) (1).mp4", t0.addingTimeInterval(1)),        // not this stem
            ("Other video [abc].mp4.part", t0.addingTimeInterval(1)),
            ("\(stem).mp3", t0.addingTimeInterval(5)),            // finished and reported
        ]
        let picked = DownloadLeftovers.select(files, stems: [stem], keep: ["\(stem).mp3"], since: t0)
        expect(picked == ["\(stem).f133.mp4", "\(stem).f140.m4a.part", "\(stem).f140.m4a.ytdl", "\(stem).temp.mp4"], "\(picked)")
        expect(DownloadLeftovers.select(files, stems: [], keep: [], since: t0).isEmpty)
        expect(DownloadLeftovers.stem(of: "/x/\(stem).mp4") == stem && DownloadLeftovers.stem(of: "a.b.c") == "a.b" && DownloadLeftovers.stem(of: "noext") == "noext")
    }

    test("video: readable errors, never naming the component") {
        let saved = Loc.language
        Loc.language = .en
        defer { Loc.language = saved }
        let cases: [([String], Int32, String)] = [
            (["ERROR: [youtube] jNQXAC9IVRw: Video unavailable"], 1, "Video unavailable"),
            (["ERROR: Unsupported URL: https://example.com/"], 1, "This site isn't supported."),
            (["ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  for how to manually pass cookies"], 1,
             "Sign in to confirm you’re not a bot."),
            (["ERROR: unable to download video data: HTTP Error 403: Forbidden"], 1,
             "The site refused the download (HTTP 403). Updating the download component often helps."),
            (["WARNING: x", "ERROR: first", "ERROR: [generic] Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known> (caused by TransportError('x'))"], 1,
             "Couldn't reach the site. Check your connection."),
            (["ERROR: [generic] Unable to download webpage: HTTP Error 404: Not Found (caused by <HTTPError 404: Not Found>)"], 1,
             "Unable to download webpage: HTTP Error 404: Not Found"),
            (["ERROR: [BiliBili] BV1: Requested format is not available. Use --list-formats for a list of available formats"], 1,
             "This quality isn't available. Try Best."),
            (["Usage: yt-dlp [OPTIONS] URL [URL...]", "", "yt-dlp: error: no such option: --js-runtimes"], 2, "The download component is too old. Update it."),
            ([], 1, "The download stopped (code 1)."),
            (["ERROR: [BiliBili] BV1GJ411x7h7: This video may be deleted or geo-restricted. You might want to try a VPN or a proxy server (with --proxy)"], 1,
             "This video may be deleted or geo-restricted. You might want to try a VPN or a proxy server"),
            (["ERROR: [vimeo] 1: The web client only works when logged-in. Confirm you are on the latest version using yt-dlp -U"], 1,
             "The web client only works when logged-in."),
            (["ERROR: [cookies] Could not copy Chrome cookie database. See  https://github.com/yt-dlp/yt-dlp/issues/7271"], 1,
             "Couldn't read the browser's sign-in. Allow access when macOS asks, or pick another browser."),
        ]
        for (lines, code, want) in cases {
            let got = DownloadErrorText.friendly(lines, exitCode: code)
            expect(got == want, "\(lines.last ?? "-") → \(got)")
            expect(!got.lowercased().contains("yt-dlp"), "names the component: \(got)")
        }
        expect(DownloadErrorText.friendly(["ERROR: " + String(repeating: "long ", count: 200)], exitCode: 1).count == 300)
    }

    test("video: where the tools are found") {
        let managed = "/Users/me/Library/Application Support/BarTap/Tools/yt-dlp"
        var present: Set<String> = ["/usr/local/bin/yt-dlp", managed, "/usr/local/bin/ffmpeg", "/usr/local/bin/node", "/Users/me/.bun/bin/bun"]
        let isExec = { (p: String) in present.contains(p) }
        let found = ToolLocator.firstYTDLP(custom: "", home: "/Users/me", managed: managed, isExecutable: isExec)
        expect(found?.path == managed && found?.source == .managed, "BarTap's own copy, once installed, comes before an old install")
        expect(ToolLocator.firstYTDLP(custom: "/Users/me/bin/yt-dlp", home: "/Users/me", managed: managed, isExecutable: isExec)?.path == managed,
               "a chosen copy that is gone is skipped")
        present.remove(managed)
        expect(ToolLocator.firstYTDLP(custom: "", home: "/Users/me", managed: managed, isExecutable: isExec)?.source == .external)
        present.insert(managed)
        present.insert("/Users/me/bin/yt-dlp")
        expect(ToolLocator.firstYTDLP(custom: "/Users/me/bin/yt-dlp", home: "/Users/me", managed: managed, isExecutable: isExec)?.source == .custom)
        present = [managed]
        expect(ToolLocator.firstYTDLP(custom: "", home: "/Users/me", managed: managed, isExecutable: isExec)?.source == .managed)
        present = []
        expect(ToolLocator.firstYTDLP(custom: "", home: "/Users/me", managed: managed, isExecutable: isExec) == nil)
        present = ["/usr/local/bin/ffmpeg", "/usr/local/bin/node", "/Users/me/.bun/bin/bun"]
        expect(ToolLocator.ffmpeg(isExecutable: isExec) == "/usr/local/bin/ffmpeg")
        expect(ToolLocator.jsRuntime(home: "/Users/me", isExecutable: isExec) == JSRuntime(name: "node", path: "/usr/local/bin/node"))
        present.insert("/Users/me/.deno/bin/deno")
        expect(ToolLocator.jsRuntime(home: "/Users/me", isExecutable: isExec)?.name == "deno", "yt-dlp's own order: deno first")
        expect(ToolLocator.source(for: "/opt/homebrew/bin/yt-dlp", resolved: "/opt/homebrew/Cellar/yt-dlp/2026.3.17_2/bin/yt-dlp") == .homebrew)
        expect(ToolLocator.source(for: "/usr/local/bin/yt-dlp", resolved: "/usr/local/bin/yt-dlp") == .external)
    }

    test("video: PATH for the component") {
        let base = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        expect(ToolLocator.searchPath(inherited: "/usr/bin:/bin:/usr/sbin:/sbin") == base, "launchd's PATH")
        expect(ToolLocator.searchPath(inherited: nil) == base)
        expect(ToolLocator.searchPath(inherited: "/opt/homebrew/bin:/Users/me/bin:/usr/bin")
               == "/opt/homebrew/bin:/usr/local/bin:/Users/me/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        expect(ToolLocator.searchPath(inherited: "/opt/homebrew/bin:/usr/bin", includeInstallDirs: false) == "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
