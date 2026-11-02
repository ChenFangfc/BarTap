import Foundation
import BarTapCore

// Video downloader: arguments, yt-dlp's output, progress, checksums, links, clean-up, errors.
// Lines below are copied from real yt-dlp 2026.03.17 runs.

private func value(_ args: [String], _ flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

private func values(_ args: [String], _ flag: String) -> [String] {
    args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
}

func runVideoDownloadTests() {
    let full = VideoToolchain(ytdlp: "/opt/homebrew/bin/yt-dlp", version: YTDLPVersion("2026.03.17"),
                              ffmpeg: "/opt/homebrew/bin/ffmpeg", js: JSRuntime(name: "deno", path: "/opt/homebrew/bin/deno"))
    var bare = full
    bare.ffmpeg = nil
    bare.js = nil
    let zoo = VideoRequest(url: "https://www.youtube.com/watch?v=jNQXAC9IVRw", preset: .best, folder: "/Users/me/Downloads", playlists: false)

    test("video: Best merges into MP4, H.264/AAC first at equal resolution") {
        let a = VideoArguments.make(zoo, tools: full)
        expect(value(a, "-f") == "bv*+ba/b", "\(value(a, "-f") ?? "-")")
        expect(value(a, "-S") == "lang,res,fps,+hasaud,ext:mp4:m4a,vcodec:h264,acodec:aac")
        expect(value(a, "--merge-output-format") == "mp4")
        expect(value(a, "--ffmpeg-location") == "/opt/homebrew/bin/ffmpeg")
        expect(value(a, "--js-runtimes") == "deno:/opt/homebrew/bin/deno")
        expect(Array(a.suffix(2)) == ["--", zoo.url], "the link comes last, after --")
        expect(value(a, "-P") == "/Users/me/Downloads" && value(a, "-o") == "%(title).200B [%(id)s].%(ext)s")
        expect(a.contains("--no-playlist") && value(a, "--playlist-items") == "1")
        expect(a.contains("--ignore-config") && a.contains("--newline") && a.contains("--progress") && a.contains("--no-update"))
        expect(value(a, "--progress-delta") == "0.5")
        expect(values(a, "--print").contains("after_move:[bartap-file] %(filepath)s"))
        expect(values(a, "--progress-template").count == 2)
        expect(!values(a, "--print").contains { $0.contains(VideoArguments.partsTag) }, "unmerged parts are only listed without ffmpeg")
    }

    test("video: resolution caps") {
        var r = zoo
        r.preset = .upTo1080
        expect(value(VideoArguments.make(r, tools: full), "-S")?.hasPrefix("lang,res:1080,") == true)
        r.preset = .upTo720
        expect(value(VideoArguments.make(r, tools: full), "-S")?.hasPrefix("lang,res:720,") == true)
    }

    test("video: without ffmpeg, H.264 + M4A streams for AVFoundation to join") {
        let a = VideoArguments.make(zoo, tools: bare)
        expect(value(a, "-f") == "bv*[vcodec^=avc1][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b")
        expect(!a.contains("--merge-output-format") && !a.contains("--ffmpeg-location") && !a.contains("--js-runtimes"))
        expect(values(a, "--print").contains("after_move:[bartap-parts] %(requested_formats.:.filepath)j"))
    }

    test("video: audio presets never re-encode, except MP3") {
        var r = zoo
        r.preset = .audio
        let a = VideoArguments.make(r, tools: full)
        expect(value(a, "-f") == "ba[ext=m4a]/ba[acodec^=mp4a]/ba/b" && a.contains("-x") && !a.contains("--audio-format"))
        let b = VideoArguments.make(r, tools: bare)
        expect(value(b, "-f") == "ba[ext=m4a]/ba[acodec^=mp4a]/ba" && !b.contains("-x"), "no ffmpeg: no extraction")
        r.preset = .mp3
        let m = VideoArguments.make(r, tools: full)
        expect(value(m, "--audio-format") == "mp3" && value(m, "--audio-quality") == "2" && m.contains("-x"))
        expect(VideoPreset.mp3.needsFFmpeg && !VideoPreset.audio.needsFFmpeg && VideoPreset.audio.isAudio && !VideoPreset.best.isAudio)
    }

    test("video: playlists") {
        var r = zoo
        r.playlists = true
        let a = VideoArguments.make(r, tools: full)
        expect(a.contains("--yes-playlist") && !a.contains("--no-playlist") && !a.contains("--playlist-items"))
    }

    test("video: options an older yt-dlp would reject are left out") {
        var old = full
        old.version = YTDLPVersion("2025.10.22")
        let a = VideoArguments.make(zoo, tools: old)
        expect(!a.contains("--js-runtimes") && a.contains("--progress-delta"))
        old.version = YTDLPVersion("2024.03.10")
        expect(!VideoArguments.make(zoo, tools: old).contains("--progress-delta"))
        var node = full
        node.js = JSRuntime(name: "node", path: "/usr/local/bin/node")
        expect(value(VideoArguments.make(zoo, tools: node), "--js-runtimes") == "node:/usr/local/bin/node")
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

    test("video: yt-dlp's output lines") {
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
        expect(VideoPreset.best.title == "Best" && VideoPreset.audio.title == "Audio Only (M4A)")
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

    test("video: readable errors") {
        let saved = Loc.language
        Loc.language = .en
        defer { Loc.language = saved }
        let cases: [([String], Int32, String)] = [
            (["ERROR: [youtube] jNQXAC9IVRw: Video unavailable"], 1, "Video unavailable"),
            (["ERROR: Unsupported URL: https://example.com/"], 1, "This site isn't supported by yt-dlp."),
            (["ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies-from-browser or --cookies for the authentication. See  https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp  for how to manually pass cookies"], 1,
             "Sign in to confirm you’re not a bot."),
            (["ERROR: unable to download video data: HTTP Error 403: Forbidden"], 1,
             "The site refused the download (HTTP 403). Updating yt-dlp often fixes this."),
            (["WARNING: x", "ERROR: first", "ERROR: [generic] Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known> (caused by TransportError('x'))"], 1,
             "Couldn't reach the site. Check your connection."),
            (["ERROR: [generic] Unable to download webpage: HTTP Error 404: Not Found (caused by <HTTPError 404: Not Found>)"], 1,
             "Unable to download webpage: HTTP Error 404: Not Found"),
            (["ERROR: [BiliBili] BV1: Requested format is not available. Use --list-formats for a list of available formats"], 1,
             "No download matches this quality. Try Best."),
            (["Usage: yt-dlp [OPTIONS] URL [URL...]", "", "yt-dlp: error: no such option: --js-runtimes"], 2, "This yt-dlp is too old for BarTap. Update it."),
            ([], 1, "yt-dlp stopped (exit code 1)."),
            (["ERROR: [BiliBili] BV1GJ411x7h7: This video may be deleted or geo-restricted. You might want to try a VPN or a proxy server (with --proxy)"], 1,
             "This video may be deleted or geo-restricted. You might want to try a VPN or a proxy server"),
        ]
        for (lines, code, want) in cases {
            let got = DownloadErrorText.friendly(lines, exitCode: code)
            expect(got == want, "\(lines.last ?? "-") → \(got)")
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

    test("video: PATH for yt-dlp") {
        let base = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        expect(ToolLocator.searchPath(inherited: "/usr/bin:/bin:/usr/sbin:/sbin") == base, "launchd's PATH")
        expect(ToolLocator.searchPath(inherited: nil) == base)
        expect(ToolLocator.searchPath(inherited: "/opt/homebrew/bin:/Users/me/bin:/usr/bin")
               == "/opt/homebrew/bin:/usr/local/bin:/Users/me/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        expect(ToolLocator.searchPath(inherited: "/opt/homebrew/bin:/usr/bin", includeInstallDirs: false) == "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
