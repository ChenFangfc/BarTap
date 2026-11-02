import AppKit
import BarTapCore

/// Headless checks of the video downloader, handled at the top of main.swift before anything
/// touches the menu bar or the app's defaults:
///   --video-download <url> <dir> [best|upTo1080|upTo720|audio|mp3] [--no-ffmpeg] [--ytdlp <path>] [--cancel-after <s>]
///   --ytdlp-install <dir>     installs BarTap's own yt-dlp into <dir> instead of Application Support
///   --render-downloads <dir>  renders the panel and the settings section to PNG, light and dark, en and zh
enum VideoDownloadCLI {
    static func handle(_ args: [String]) -> Int32? {
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

    private static func download(_ args: [String], at i: Int) -> Int32 {
        let (settings, discard) = scratchSettings()
        defer { discard() }
        let folder = URL(fileURLWithPath: args[i + 2]).standardizedFileURL.path
        let preset = (i + 3 < args.count ? VideoPreset(rawValue: args[i + 3]) : nil) ?? .best
        settings.videoFolder = folder
        if let j = args.firstIndex(of: "--ytdlp"), j + 1 < args.count { settings.videoToolPath = args[j + 1] }
        VideoTools.ignoreFFmpeg = args.contains("--no-ffmpeg")
        // Never look at (or install into) the real Application Support folder from a test.
        VideoTools.managedDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bartap-no-tools-\(getpid())")
        let downloads = VideoDownloads.shared
        downloads.settings = settings
        downloads.announce = { _ in }

        guard let link = LinkDetector.firstWebURL(in: args[i + 1]) else {
            print("not a link: \(args[i + 1])")
            return 2
        }
        let tools = VideoTools.shared
        var ready = false
        tools.refresh { ready = true }
        spin(until: { ready }, timeout: 90)
        print("tools: \(tools.summary)")
        if let chain = tools.status.toolchain {
            let request = VideoRequest(url: link, preset: preset, folder: folder, playlists: false)
            print("args: " + VideoArguments.make(request, tools: chain).map { $0.contains(" ") || $0.contains("*") ? "'\($0)'" : $0 }.joined(separator: " "))
        }

        let cpuStart = ProcessStats.cpuSeconds(), started = Date()
        var peak = ProcessStats.memoryMB()
        let job = downloads.add(url: link, preset: preset)
        var last = ""
        let observer = NotificationCenter.default.addObserver(forName: .barTapDownloadsChanged, object: nil, queue: .main) { _ in
            let line = String(format: "%6.1fs  %@  %@", Date().timeIntervalSince(started), "\(job.state)", job.statusText)
            if line.dropFirst(8) != last.dropFirst(8) { print(line) }
            last = line
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        if let j = args.firstIndex(of: "--cancel-after"), j + 1 < args.count, let after = Double(args[j + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                print("cancelling after \(after) s")
                downloads.cancel(job)
            }
        }
        spin(until: { !job.state.isActive }, timeout: 3600) { peak = max(peak, ProcessStats.memoryMB()) }

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
        print(String(format: "BarTap side: peak footprint %.1f MB, CPU %.2f s over %.1f s; yt-dlp and helpers: CPU %.2f s",
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
        print(String(format: "took %.1f s; status: %@ (%@)", Date().timeIntervalSince(started), tools.summary, tools.status.path ?? "-"))
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
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("Me at the zoo [jNQXAC9IVRw].mp4")
        FileManager.default.createFile(atPath: sample.path, contents: nil)
        try? FileHandle(forWritingTo: sample).truncate(atOffset: 744_412)
        defer { try? FileManager.default.removeItem(at: sample) }

        let tools = VideoTools.shared
        let ready = VideoTools.Status(path: "/Users/you/Library/Application Support/BarTap/Tools/yt-dlp/yt-dlp_macos", source: .managed,
                                      version: YTDLPVersion("2026.10.26"), ffmpeg: "/opt/homebrew/bin/ffmpeg",
                                      js: JSRuntime(name: "deno", path: "/opt/homebrew/bin/deno"))
        let old = VideoTools.Status(path: "/opt/homebrew/bin/yt-dlp", source: .homebrew, version: YTDLPVersion("2026.03.17"))
        let missing = VideoTools.Status()
        for language in [AppLanguage.en, .zhHans] {
            Loc.language = language
            let tag = language == .en ? "en" : "zh"
            for dark in [false, true] {
                let theme = dark ? "dark" : "light"
                tools.setPreview(ready)
                downloads.setJobsForPreview(previewJobs(sample: sample.path))
                capturePanel(dark: dark, to: dir.appendingPathComponent("downloads_panel_\(tag)_\(theme).png"))
                tools.setPreview(missing)
                downloads.setJobsForPreview([])
                capturePanel(dark: dark, to: dir.appendingPathComponent("downloads_panel_empty_\(tag)_\(theme).png"))
                for (name, status) in [("ready", ready), ("homebrew", old), ("missing", missing)] {
                    tools.setPreview(status, install: name == "missing" ? .running(L("Downloading yt-dlp %@…", "2026.10.26"), 0.42) : .idle)
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

    private static func previewJobs(sample: String) -> [DownloadJob] {
        func job(_ url: String, _ preset: VideoPreset, _ state: DownloadJob.State, title: String? = nil, _ configure: (DownloadJob) -> Void = { _ in }) -> DownloadJob {
            let j = DownloadJob(url: url, preset: preset, folder: "/Users/you/Downloads", playlists: false)
            j.state = state
            j.title = title
            configure(j)
            return j
        }
        let item = DownloadItem(id: "aqz-KE-bpKQ", title: "", formatID: "299+140", ext: "mp4", approxBytes: 52_000_000, filename: "/tmp/x.mp4")
        return [
            job("https://www.youtube.com/watch?v=aqz-KE-bpKQ", .best, .running, title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film") { j in
                j.meter.begin(item)
                j.meter.update(DownloadProgress(finished: false, downloaded: 21_800_000, total: 48_000_000, estimate: nil, speed: 3_250_000, eta: 8, fragment: nil, fragments: nil, formatID: "299"))
            },
            job("https://www.youtube.com/playlist?list=PL1", .audio, .finishing, title: "Lecture 2: Linear Algebra Review") { j in
                j.item = (2, 15)
                j.step = L("Merging video and audio…")
            },
            job("https://vimeo.com/76979871", .upTo1080, .queued),
            job("https://www.youtube.com/watch?v=jNQXAC9IVRw", .best, .done, title: "Me at the zoo") { $0.files = [sample] },
            job("https://www.youtube.com/watch?v=xxxxxxxxxxx", .best, .failed, title: "Members-only stream") { j in
                j.message = "Sign in to confirm you’re not a bot. This helps protect our community."
            },
            job("https://example.com/not-a-video", .best, .failed) { $0.message = L("This site isn't supported by yt-dlp.") },
            job("https://www.bilibili.com/video/BV1GJ411x7h7", .best, .cancelled, title: "【官方 MV】Never Gonna Give You Up - Rick Astley"),
        ]
    }

    private static func capturePanel(dark: Bool, to url: URL) {
        let panel = DownloadPanel(model: VideoDownloads.shared)
        panel.isRendering = true
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.rebuildPresets()
        panel.reloadJobs()
        panel.refreshTools()
        let view = panel.renderView
        view.layoutSubtreeIfNeeded()
        draw(view, size: view.fittingSize, dark: dark, to: url)
        panel.isRendering = false
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
