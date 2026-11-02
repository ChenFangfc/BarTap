import AppKit
import BarTapCore

/// Headless checks of the video downloader, handled at the top of main.swift before anything
/// touches the menu bar or the app's defaults:
///   --video-info <url> [--ytdlp <path>]
///   --video-download <url> <dir> [--quality best|1080|…|audio] [--format mp4|mkv|webm|m4a|mp3|opus]
///       [--subs file|embed] [--sub-lang <code>] [--auto-subs] [--clip <start>-<end>] [--playlist all|single|<items>]
///       [--sponsors keep|mark|remove] [--name title|titleID|uploaderTitle|dateTitle] [--limit <KB/s>]
///       [--audio-quality best|k320|k192|k128] [--no-embed] [--pause-after <s> [--resume-after <s>]]
///       [--cancel-after <s>] [--no-ffmpeg] [--ytdlp <path>]
///   --ytdlp-install <dir>     installs BarTap's own copy into <dir> instead of Application Support
///   --render-downloads <dir>  renders the panel's states and the settings section to PNG
enum VideoDownloadCLI {
    static func handle(_ args: [String]) -> Int32? {
        if let i = args.firstIndex(of: "--video-info"), i + 1 < args.count { return info(args, at: i) }
        if let i = args.firstIndex(of: "--video-download"), i + 2 < args.count { return download(args, at: i) }
        if let i = args.firstIndex(of: "--ytdlp-install"), i + 1 < args.count { return install(into: URL(fileURLWithPath: args[i + 1])) }
        if let i = args.firstIndex(of: "--render-downloads"), i + 1 < args.count { return render(to: URL(fileURLWithPath: args[i + 1])) }
        return nil
    }

    /// Default settings in a throwaway file (a named suite would leave a plist in ~/Library/Preferences).
    private static func scratchSettings() -> (Settings, () -> Void) {
        let path = NSTemporaryDirectory() + "bartap-video-\(UUID().uuidString).plist"
        let settings = Settings(defaults: UserDefaults(suiteName: path)!)
        return (settings, {
            CFPreferencesAppSynchronize(path as CFString)
            try? FileManager.default.removeItem(atPath: path)
        })
    }

    private static func spin(until done: () -> Bool, timeout: TimeInterval, tick: () -> Void = {}) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            tick()
        }
    }

    private static func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    /// Scratch settings, the tools this Mac has (or the copy given with --ytdlp), never the real
    /// Application Support folder.
    private static func prepare(_ args: [String], settings: Settings) -> Bool {
        if let path = value(args, "--ytdlp") { settings.videoToolPath = path }
        VideoTools.ignoreFFmpeg = args.contains("--no-ffmpeg")
        VideoTools.managedDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bartap-no-tools-\(getpid())")
        VideoDownloads.shared.settings = settings
        VideoDownloads.shared.announce = { _ in }
        var ready = false
        VideoTools.shared.refresh { ready = true }
        spin(until: { ready }, timeout: 90)
        print("component: \(VideoTools.shared.statusLine)" + (VideoTools.shared.problems.isEmpty ? "" : "  [\(VideoTools.shared.problems.joined(separator: "; "))]"))
        return VideoTools.shared.status.toolchain != nil
    }

    private static func info(_ args: [String], at i: Int) -> Int32 {
        let (settings, discard) = scratchSettings()
        defer { discard() }
        guard prepare(args, settings: settings), let link = LinkDetector.firstWebURL(in: args[i + 1]) else { return 2 }
        let started = Date()
        var result: Result<VideoInfo, VideoDownloads.InfoError>?
        VideoDownloads.shared.fetchInfo(url: link, browser: nil) { result = $0 }
        spin(until: { result != nil }, timeout: 300)
        print(String(format: "took %.1f s", Date().timeIntervalSince(started)))
        switch result {
        case .success(let info)?:
            print("title: \(info.title)")
            print("uploader: \(info.uploader ?? "-") · duration: \(info.duration.map { DownloadText.duration($0) } ?? "-") · live: \(info.isLive)")
            if let n = info.playlistCount { print("playlist: \(n) videos") }
            print("thumbnail: \(info.thumbnail ?? "-")")
            for q in info.qualities {
                print("quality: \(q.title)  " + VideoContainer.allCases.map { c in "\(c.title) \(q.bytes[c].map { StatFormat.bytes(UInt64($0)) } ?? "?")" }.joined(separator: "  "))
            }
            print("audio: " + AudioFormat.allCases.map { f in "\(f.title) \((f == .mp3 ? info.mp3Bytes(.best) : info.audioBytes[f]).map { StatFormat.bytes(UInt64($0)) } ?? "?")" }.joined(separator: "  "))
            print("subtitles: \(info.subtitles.joined(separator: ", ")) · generated: \(info.autoSubtitles.prefix(12).joined(separator: ", "))\(info.autoSubtitles.count > 12 ? "… (\(info.autoSubtitles.count))" : "")")
            return 0
        case .failure(let e)?:
            print("failed: \(e.message)")
            return 1
        case nil:
            print("timed out")
            return 1
        }
    }

    private static func download(_ args: [String], at i: Int) -> Int32 {
        let (settings, discard) = scratchSettings()
        defer { discard() }
        let folder = URL(fileURLWithPath: args[i + 2]).standardizedFileURL.path
        settings.videoFolder = folder
        guard let link = LinkDetector.firstWebURL(in: args[i + 1]) else {
            print("not a link: \(args[i + 1])")
            return 2
        }
        guard prepare(args, settings: settings) else { print("no download component"); return 2 }
        let downloads = VideoDownloads.shared
        var o = VideoOptions()
        if let f = value(args, "--format") {
            if let c = VideoContainer(rawValue: f) { o.container = c }
            if let a = AudioFormat(rawValue: f) { o.audioFormat = a }
        }
        if let s = value(args, "--subs").flatMap(SubtitleMode.init(rawValue:)) { o.subtitles = s }
        if let l = value(args, "--sub-lang") { o.subtitleLanguage = l }
        o.autoSubtitles = args.contains("--auto-subs")
        if let s = value(args, "--sponsors").flatMap(SponsorMode.init(rawValue:)) { o.sponsors = s }
        if let n = value(args, "--name").flatMap(FileNameStyle.init(rawValue:)) { o.fileName = n }
        if let l = value(args, "--limit").flatMap(Int.init) { o.speedLimit = l }
        if let q = value(args, "--audio-quality").flatMap(AudioQuality.init(rawValue:)) { o.audioQuality = q }
        if args.contains("--no-embed") { o.embedThumbnail = false; o.embedMetadata = false; o.embedChapters = false }
        var request = downloads.request(url: link, quality: value(args, "--quality").flatMap(VideoQuality.init(storage:)) ?? .best)
        request.options = o
        switch value(args, "--playlist") {
        case "all"?: request.playlist = .all
        case let items? where items != "single": request.playlist = PlaylistItems.normalize(items).map { .items($0) } ?? .single
        default: break
        }
        if let clip = value(args, "--clip") {
            let ends = clip.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if case .valid(let range) = ClipRange.parse(start: ends.first ?? "", end: ends.count > 1 ? ends[1] : "") { request.clip = range }
        }
        if let chain = VideoTools.shared.status.toolchain {
            print("args: " + VideoArguments.make(request, tools: chain).map { $0.contains(" ") || $0.contains("*") ? "'\($0)'" : $0 }.joined(separator: " "))
        }

        let cpuStart = ProcessStats.cpuSeconds(), started = Date()
        var peak = ProcessStats.memoryMB()
        let job = downloads.add(request)
        var last = ""
        let observer = NotificationCenter.default.addObserver(forName: .barTapDownloadsChanged, object: nil, queue: .main) { _ in
            let line = String(format: "%6.1fs  %@  %@", Date().timeIntervalSince(started), "\(job.state)", job.statusText)
            if line.dropFirst(8) != last.dropFirst(8) { print(line) }
            last = line
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        if let after = value(args, "--cancel-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("cancelling after \(after) s")
                downloads.cancel(job)
            }
        }
        if let after = value(args, "--pause-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("pausing after \(after) s")
                downloads.pause(job)
            }
        }
        let resumeAfter = value(args, "--resume-after").flatMap(Double.init)
        var resumeScheduled = false
        // Stop waiting at the end, or at a pause nobody resumes.
        spin(until: { !job.state.isActive && (job.state != .paused || resumeAfter == nil) }, timeout: 3600) {
            peak = max(peak, ProcessStats.memoryMB())
            guard job.state == .paused, let wait = resumeAfter, !resumeScheduled else { return }
            resumeScheduled = true
            let sizes = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().map { name -> String in
                let size = (try? FileManager.default.attributesOfItem(atPath: folder + "/" + name))?[.size] as? NSNumber
                return "\(name) (\(size?.int64Value ?? 0) bytes)"
            }
            print("paused; folder: \(sizes.joined(separator: " | "))")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                print("resuming after \(wait) s")
                downloads.resume(job)
            }
        }

        var children = rusage()
        getrusage(RUSAGE_CHILDREN, &children)
        let childCPU = Double(children.ru_utime.tv_sec + children.ru_stime.tv_sec) + Double(children.ru_utime.tv_usec + children.ru_stime.tv_usec) / 1e6
        print("title: \(job.title ?? "-")")
        print("state: \(job.state)\(job.message.map { " — \($0)" } ?? "")")
        for f in job.files {
            let size = (try? FileManager.default.attributesOfItem(atPath: f))?[.size] as? NSNumber
            print("file: \(f) (\(size.map { "\($0.int64Value) bytes" } ?? "missing"))")
        }
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
        print("folder now: \(left.isEmpty ? "(empty)" : left.joined(separator: " | "))")
        print(String(format: "BarTap side: peak footprint %.1f MB, CPU %.2f s over %.1f s; download component and helpers: CPU %.2f s",
                     peak, ProcessStats.cpuSeconds() - cpuStart, Date().timeIntervalSince(started), childCPU))
        return job.state == .done ? 0 : 1
    }

    private static func install(into dir: URL) -> Int32 {
        let (settings, discard) = scratchSettings()
        defer { discard() }
        VideoDownloads.shared.settings = settings
        VideoTools.managedDirectory = dir
        let tools = VideoTools.shared
        var last = ""
        let observer = NotificationCenter.default.addObserver(forName: .barTapVideoToolsChanged, object: nil, queue: .main) { _ in
            let line: String
            switch tools.install {
            case .running(let text, let f): line = text + (f.map { " " + StatFormat.percent($0) } ?? "")
            case .failed(let why): line = "failed: " + why
            case .finished(let what): line = "finished: " + what
            case .idle: line = "idle"
            }
            if line != last { print(line) }
            last = line
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let started = Date()
        tools.installManaged()
        spin(until: { !tools.isInstalling }, timeout: 1800)
        spin(until: { !tools.status.checking }, timeout: 120)
        print(String(format: "took %.1f s; component: %@ (%@)", Date().timeIntervalSince(started), tools.statusLine, tools.status.path ?? "-"))
        if case .finished = tools.install { return 0 }
        return 1
    }

    // MARK: Renders

    private static func render(to dir: URL) -> Int32 {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (settings, discard) = scratchSettings()
        defer { discard() }
        let downloads = VideoDownloads.shared
        downloads.settings = settings
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("Me at the zoo.mp4")
        FileManager.default.createFile(atPath: sample.path, contents: nil)
        try? FileHandle(forWritingTo: sample).truncate(atOffset: 744_412)
        defer { try? FileManager.default.removeItem(at: sample) }

        let tools = VideoTools.shared
        let ready = VideoTools.Status(path: "/Users/you/Library/Application Support/BarTap/Tools/yt-dlp/yt-dlp_macos", source: .managed,
                                      version: YTDLPVersion("2026.10.26"), ffmpeg: "/opt/homebrew/bin/ffmpeg",
                                      js: JSRuntime(name: "deno", path: "/opt/homebrew/bin/deno"))
        let old = VideoTools.Status(path: "/opt/homebrew/bin/yt-dlp", source: .homebrew, version: YTDLPVersion("2026.03.17"))
        let missing = VideoTools.Status()
        let thumbnail = sampleThumbnail()
        for language in [AppLanguage.en, .zhHans] {
            Loc.language = language
            let tag = language == .en ? "en" : "zh"
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                func panel(_ name: String, _ setup: (DownloadPanel) -> Void) {
                    let p = DownloadPanel(model: downloads)
                    p.isRendering = true
                    p.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    p.rebuildFolders()
                    p.reloadJobs()
                    p.refreshComponent()
                    setup(p)
                    let view = p.renderView
                    view.layoutSubtreeIfNeeded()
                    draw(view, size: view.fittingSize, dark: dark, to: dir.appendingPathComponent("downloads_\(name)_\(tag)_\(theme).png"))
                    p.isRendering = false
                }
                tools.setPreview(ready)
                downloads.setJobsForPreview([])
                panel("empty") { _ in }
                panel("preview") { $0.showPreview(link: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", info: sampleInfo(), thumbnail: thumbnail) }
                panel("options") { p in
                    p.showPreview(link: "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=PL1", info: sampleInfo(), thumbnail: thumbnail)
                    p.setOptionsOpen(true)
                }
                downloads.setJobsForPreview(previewJobs(sample: sample.path, thumbnail: thumbnail))
                panel("queue") { _ in }
                tools.setPreview(missing)
                downloads.setJobsForPreview([])
                panel("missing") { _ in }
                for (name, status) in [("ready", ready), ("homebrew", old), ("missing", missing)] {
                    tools.setPreview(status, install: name == "missing" ? .running(L("Downloading %@…", "2026.10.26"), 0.42) : .idle)
                    let form = Form()
                    VideoDownloadSettings.build(form, settings: settings)
                    capture(form.stack, width: 640, dark: dark, to: dir.appendingPathComponent("downloads_settings_\(name)_\(tag)_\(theme).png"))
                }
            }
        }
        Loc.language = .system
        print("rendered to \(dir.path)")
        return 0
    }

    /// A stand-in thumbnail (no network in renders).
    private static func sampleThumbnail() -> NSImage {
        NSImage(size: NSSize(width: 256, height: 144), flipped: false) { r in
            NSGradient(colors: [NSColor(red: 0.36, green: 0.62, blue: 0.32, alpha: 1), NSColor(red: 0.12, green: 0.34, blue: 0.52, alpha: 1)])?.draw(in: r, angle: -35)
            NSColor(white: 1, alpha: 0.85).setFill()
            let play = NSBezierPath()
            play.move(to: NSPoint(x: r.midX - 16, y: r.midY - 20))
            play.line(to: NSPoint(x: r.midX + 22, y: r.midY))
            play.line(to: NSPoint(x: r.midX - 16, y: r.midY + 20))
            play.close()
            play.fill()
            return true
        }
    }

    /// Big Buck Bunny's real resolutions, with plausible sizes.
    private static func sampleInfo() -> VideoInfo {
        let mb: Int64 = 1_000_000
        let q: [(Int, Bool, Int64)] = [(2160, true, 1_820), (1440, true, 980), (1080, true, 412), (720, true, 228), (480, false, 96), (360, false, 61), (240, false, 33), (144, false, 15)]
        return VideoInfo(title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film", uploader: "Blender", duration: 635,
                         thumbnail: nil, qualities: q.map { h, hfr, size in
                             QualityOption(height: h, highFrameRate: hfr, bytes: [.mp4: size * mb, .mkv: size * mb * 9 / 10, .webm: size * mb * 9 / 10])
                         }, audioBytes: [.m4a: 10 * mb, .opus: 9 * mb], subtitles: ["en", "de", "zh-Hans"], autoSubtitles: ["en"])
    }

    private static func previewJobs(sample: String, thumbnail: NSImage) -> [DownloadJob] {
        func job(_ url: String, _ quality: VideoQuality, _ state: DownloadJob.State, title: String? = nil, thumb: Bool = false,
                 _ configure: (DownloadJob) -> Void = { _ in }) -> DownloadJob {
            let j = DownloadJob(request: VideoRequest(url: url, quality: quality, folder: "/Users/you/Downloads"), title: title, thumbnail: thumb ? thumbnail : nil)
            j.state = state
            configure(j)
            return j
        }
        let item = DownloadItem(id: "aqz-KE-bpKQ", title: "", formatID: "299+140", ext: "mp4", approxBytes: 52_000_000, filename: "/tmp/x.mp4")
        return [
            job("https://www.youtube.com/watch?v=aqz-KE-bpKQ", .height(1080), .running, title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film", thumb: true) { j in
                j.meter.begin(item)
                j.meter.update(DownloadProgress(finished: false, downloaded: 21_800_000, total: 48_000_000, speed: 3_250_000, formatID: "299"))
            },
            job("https://www.youtube.com/playlist?list=PL1", .audio, .finishing, title: "Lecture 2: Linear Algebra Review") { j in
                j.item = (2, 15)
                j.step = L("Converting to %@…", "MP3")
            },
            job("https://vimeo.com/76979871", .height(720), .paused, title: "The New Vimeo Player (You Know, For Videos)") { j in
                j.meter.begin(item)
                j.meter.update(DownloadProgress(finished: false, downloaded: 18_000_000, total: 52_000_000, formatID: "299"))
            },
            job("https://www.youtube.com/watch?v=jNQXAC9IVRw&t=1", .best, .queued),
            job("https://www.youtube.com/watch?v=jNQXAC9IVRw", .best, .done, title: "Me at the zoo", thumb: true) { $0.files = [sample] },
            job("https://www.youtube.com/watch?v=xxxxxxxxxxx", .best, .failed, title: "Members-only stream") { j in
                j.message = "Join this channel to get access to members-only content like this video."
            },
            job("https://example.com/not-a-video", .best, .failed) { $0.message = L("This site isn't supported.") },
        ]
    }

    private static func capture(_ view: NSView, width: CGFloat, dark: Bool, to url: URL) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: ceil(view.fittingSize.height))
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(origin: .zero, size: size)
        draw(view, size: size, dark: dark, to: url)
    }

    /// At 2x on a solid window-colored background (an offscreen material view renders flat gray).
    private static func draw(_ view: NSView, size: NSSize, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        let back = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = back
        view.removeFromSuperview()
        back.addSubview(view)
        view.frame = NSRect(origin: .zero, size: size)
        back.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.restoreGraphicsState()
            back.cacheDisplay(in: back.bounds, to: rep)
        }
        view.removeFromSuperview()
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
