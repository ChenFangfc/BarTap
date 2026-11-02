import AppKit
import AVFoundation
import CryptoKit
import BarTapCore

// Video downloads through yt-dlp (https://github.com/yt-dlp/yt-dlp), which runs as a separate
// program only while a download or a version check is under way. Nothing here starts on its
// own: no timers, no polling, no network access until the user asks for something.

extension Notification.Name {
    /// Object: the job that changed, or nil when jobs were added or removed.
    static let barTapDownloadsChanged = Notification.Name("BarTapDownloadsChanged")
    static let barTapVideoToolsChanged = Notification.Name("BarTapVideoToolsChanged")
}

// MARK: - Process

/// Runs a program and hands its output to the main queue line by line. Foundation makes the
/// child the leader of its own process group, so a signal to the group also reaches the ffmpeg
/// and JavaScript helpers yt-dlp starts (like ⌃C in Terminal).
final class LineProcess {
    private let process = Process()
    private let pipes = [Pipe(), Pipe()]
    private let lock = NSLock()
    private var pending = [Data(), Data()]
    private let group = DispatchGroup()
    /// The flag is true for stderr.
    var onLine: ((String, Bool) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// A line without a newline is dropped past this, so memory stays bounded.
    private static let maxLine = 64 * 1024

    init(_ executable: String, _ arguments: [String], environment: [String: String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
    }

    var isRunning: Bool { process.isRunning }

    /// The closures keep this object alive until the program has exited and its output is read.
    func start() throws {
        group.enter()
        process.terminationHandler = { _ in self.group.leave() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            group.leave()
            throw error
        }
        for i in 0..<2 {
            group.enter()
            pipes[i].fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                self.received(data, stream: i)
            }
        }
        group.notify(queue: .main) {
            let status = self.process.terminationStatus
            self.process.terminationHandler = nil
            self.onExit?(status)
            self.onLine = nil
            self.onExit = nil
        }
    }

    private func received(_ data: Data, stream: Int) {
        var lines: [String] = []
        lock.lock()
        var buffer = pending[stream]
        buffer.append(data)
        while let nl = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            if nl > buffer.startIndex { lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if data.isEmpty, !buffer.isEmpty {
            lines.append(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        if buffer.count > Self.maxLine { buffer.removeAll() }
        pending[stream] = buffer
        lock.unlock()
        if !lines.isEmpty {
            DispatchQueue.main.async { lines.forEach { self.onLine?($0, stream == 1) } }
        }
        if data.isEmpty { group.leave() }
    }

    func signal(_ sig: Int32) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        // Only ever the child's own group, never BarTap's.
        if getpgid(pid) == pid { killpg(pid, sig) } else { kill(pid, sig) }
    }
}

// MARK: - Tools

/// Finds yt-dlp, ffmpeg and a JavaScript runtime, and installs BarTap's own copy of yt-dlp
/// when the user asks for it.
final class VideoTools {
    static let shared = VideoTools()

    /// BarTap's own copy lives in <this>/yt-dlp/; tests point this at a temporary folder.
    static var managedDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BarTap/Tools", isDirectory: true)
    static var managedFolder: URL { managedDirectory.appendingPathComponent("yt-dlp", isDirectory: true) }
    static var managedPath: String { managedFolder.appendingPathComponent(YTDLPRelease.executable).path }
    /// Headless check of the no-ffmpeg path: behave as if ffmpeg were not installed.
    static var ignoreFFmpeg = false

    struct Status: Equatable {
        var path: String?
        var source: ToolSource?
        var version: YTDLPVersion?
        var checking = false
        var ffmpeg: String?
        var js: JSRuntime?

        var toolchain: VideoToolchain? {
            guard let path, let version else { return nil }
            return VideoToolchain(ytdlp: path, version: version, ffmpeg: ffmpeg, js: js)
        }
    }

    enum Install: Equatable {
        case idle
        case running(String, Double?)
        case failed(String)
        case finished(String)
    }

    private(set) var status = Status(checking: true)
    private(set) var install = Install.idle
    private(set) var lookedUp = false
    private var versions: [String: (stamp: String, version: YTDLPVersion?)] = [:]
    private var waiting: [() -> Void] = []
    private var installer: ManagedInstaller?

    /// Looks the tools up again (a few file checks) and reads yt-dlp's version when the file
    /// changed since the last look; `then` runs once the status is final.
    func refresh(then done: (() -> Void)? = nil) {
        if let done { waiting.append(done) }
        let home = NSHomeDirectory()
        var s = Status()
        if let found = ToolLocator.firstYTDLP(custom: VideoDownloads.shared.settings.videoToolPath, home: home,
                                              managed: Self.managedPath, isExecutable: Self.isExecutable) {
            s.path = found.path
            s.source = found.source == .external
                ? ToolLocator.source(for: found.path, resolved: URL(fileURLWithPath: found.path).resolvingSymlinksInPath().path)
                : found.source
        }
        s.ffmpeg = Self.ignoreFFmpeg ? nil : ToolLocator.ffmpeg(isExecutable: Self.isExecutable)
        s.js = ToolLocator.jsRuntime(home: home, isExecutable: Self.isExecutable)
        guard let path = s.path else { publish(s); return }
        let stamp = Self.stamp(path)
        if let known = versions[path], known.stamp == stamp {
            s.version = known.version
            publish(s)
            return
        }
        s.checking = true
        publish(s, final: false)
        Self.readVersion(path) { [weak self] version in
            guard let self else { return }
            self.versions[path] = (stamp, version)
            guard self.status.path == path else { return }
            var now = self.status
            now.version = version
            now.checking = false
            self.publish(now)
        }
    }

    private func publish(_ s: Status, final: Bool = true) {
        status = s
        if final { lookedUp = true }
        NotificationCenter.default.post(name: .barTapVideoToolsChanged, object: nil)
        guard final else { return }
        let run = waiting
        waiting = []
        run.forEach { $0() }
        VideoDownloads.shared.toolsChanged()
    }

    static func isExecutable(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func stamp(_ path: String) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\((a?[.size] as? NSNumber)?.int64Value ?? 0)"
    }

    /// `yt-dlp --version`; nil if it doesn't run. A copy that hangs is killed after a minute.
    static func readVersion(_ path: String, completion: @escaping (YTDLPVersion?) -> Void) {
        let p = LineProcess(path, ["--version"], environment: VideoDownloads.environment())
        var version: YTDLPVersion?
        var finished = false
        p.onLine = { line, isError in if !isError && version == nil { version = YTDLPVersion(line) } }
        p.onExit = { status in
            finished = true
            completion(status == 0 ? version : nil)
        }
        do { try p.start() } catch { completion(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if !finished { p.signal(SIGKILL) } }
    }

    /// Headless renders show fixed states instead of this Mac's tools.
    func setPreview(_ s: Status, install: Install = .idle) {
        status = s
        self.install = install
        lookedUp = true
    }

    // MARK: Text

    /// "yt-dlp 2026.03.17 · ffmpeg found · Deno found".
    var summary: String {
        let s = status
        if s.path == nil { return lookedUp ? L("yt-dlp isn't installed") : L("Checking yt-dlp…") }
        guard let v = s.version else { return s.checking ? L("Checking yt-dlp…") : L("yt-dlp didn't start") }
        var parts = ["yt-dlp \(v)", s.ffmpeg != nil ? L("ffmpeg found") : L("no ffmpeg")]
        if v.hasJSRuntimes { parts.append(s.js.map { L("%@ found", $0.displayName) } ?? L("no JavaScript runtime")) }
        return parts.joined(separator: " · ")
    }

    /// Where the copy in use comes from, for Settings.
    var sourceText: String? {
        guard let path = status.path, let source = status.source else { return nil }
        switch source {
        case .managed: return L("Downloaded by BarTap")
        case .homebrew: return L("Installed with Homebrew")
        case .custom: return L("Chosen by you: %@", (path as NSString).abbreviatingWithTildeInPath)
        case .external: return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// What is missing or old, most important first.
    func hints(compact: Bool) -> [String] {
        guard status.path != nil, let v = status.version else { return [] }
        var h: [String] = []
        if v < YTDLPVersion.minimum {
            h.append(L("This yt-dlp is too old for BarTap. Update it."))
        } else if v.isStale() {
            h.append(L("This yt-dlp is %d days old. Sites change often; update it if downloads fail.", v.ageInDays() ?? 0))
        }
        if v.hasJSRuntimes && status.js == nil { h.append(L("YouTube needs a JavaScript runtime for all formats: brew install deno")) }
        if !compact {
            if status.ffmpeg == nil {
                h.append(L("Without ffmpeg, videos are H.264 only (YouTube: up to 1080p) and MP3 is unavailable: brew install ffmpeg"))
            }
            if status.source == .homebrew { h.append(L("Update with brew upgrade yt-dlp")) }
        }
        return h
    }

    // MARK: BarTap's own copy

    var isInstalling: Bool { if case .running = install { return true } else { return false } }

    /// yt-dlp loads parts of itself while it runs, so the copy in use must not change under it.
    private var managedCopyBusy: Bool {
        status.source == .managed && VideoDownloads.shared.jobs.contains { $0.state == .running }
    }

    /// Downloads the latest official build, or confirms the one in place is current.
    func installManaged() {
        guard !isInstalling else { return }
        if managedCopyBusy {
            install = .failed(L("Wait until the downloads finish."))
            NotificationCenter.default.post(name: .barTapVideoToolsChanged, object: nil)
            return
        }
        let i = ManagedInstaller(directory: Self.managedDirectory)
        installer = i
        i.onState = { [weak self] state in
            guard let self else { return }
            self.install = state
            if case .running = state {} else {
                self.installer = nil
                self.refresh()
            }
            NotificationCenter.default.post(name: .barTapVideoToolsChanged, object: nil)
        }
        i.start()
    }

    func cancelInstall() { installer?.cancel() }

    /// An old "installed" or "failed" message is news only until the next time the user looks.
    func forgetInstallResult() {
        if !isInstalling { install = .idle }
    }

    func removeManaged() {
        if managedCopyBusy {
            install = .failed(L("Wait until the downloads finish."))
            NotificationCenter.default.post(name: .barTapVideoToolsChanged, object: nil)
            return
        }
        try? FileManager.default.removeItem(at: Self.managedFolder)
        install = .idle
        refresh()
    }
}

/// Fetches yt-dlp's official macOS build: the release's checksum list first (its redirect names
/// the release), then that release's zip, checked against the list, unpacked next to the
/// current copy, run once, and only then swapped in with one atomic rename.
private final class ManagedInstaller: NSObject, URLSessionDownloadDelegate {
    var onState: ((VideoTools.Install) -> Void)?
    private let directory: URL
    private var session: URLSession?
    private var task: URLSessionTask?
    // Touched only on the session's serial delegate queue, or on main once the session is done.
    private var tag: String?
    private var expected: String?
    private var archive: URL?
    private var problem: String?
    private var lastPercent = -1
    private let lock = NSLock()
    private var cancelled = false

    init(directory: URL) {
        self.directory = directory
    }

    private var unpacked: URL { directory.appendingPathComponent(".yt-dlp.new", isDirectory: true) }

    func start() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 30 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        report(.running(L("Checking the latest release…"), nil))
        let t = session.dataTask(with: YTDLPRelease.latestSums) { [weak self] data, response, error in
            self?.receivedSums(data, response, error)
        }
        task = t
        t.resume()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        task?.cancel()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func report(_ state: VideoTools.Install) {
        DispatchQueue.main.async { self.onState?(state) }
    }

    private func end(_ state: VideoTools.Install) {
        if let archive { try? FileManager.default.removeItem(at: archive) }
        try? FileManager.default.removeItem(at: unpacked)
        session?.finishTasksAndInvalidate()   // releases this delegate
        report(isCancelled ? .idle : state)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if tag == nil, let url = request.url { tag = YTDLPRelease.tag(fromRedirect: url) }
        completionHandler(request)
    }

    private func receivedSums(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
        guard !isCancelled else { end(.idle); return }
        guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data,
              let sum = ChecksumList.sha256(for: YTDLPRelease.asset, in: String(decoding: data, as: UTF8.self)) else {
            end(.failed(error.map { L("Couldn't reach GitHub: %@", $0.localizedDescription) } ?? L("Couldn't read yt-dlp's release checksums.")))
            return
        }
        expected = sum
        DispatchQueue.main.async {
            // Already this release? Then there is nothing to download.
            let current = VideoTools.isExecutable(VideoTools.managedPath) ? VideoTools.managedPath : nil
            let check: (@escaping (YTDLPVersion?) -> Void) -> Void = { done in
                if let current { VideoTools.readVersion(current, completion: done) } else { done(nil) }
            }
            check { installed in
                if let tag = self.tag, let installed, installed.description == tag {
                    self.end(.finished(L("yt-dlp is up to date.")))
                    return
                }
                self.report(.running(L("Downloading yt-dlp %@…", self.tag ?? ""), 0))
                let t = self.session?.downloadTask(with: YTDLPRelease.assetURL(tag: self.tag))
                self.task = t
                t?.resume()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(100 * totalBytesWritten / totalBytesExpectedToWrite)
        guard percent != lastPercent else { return }
        lastPercent = percent
        report(.running(L("Downloading yt-dlp %@…", tag ?? ""), Double(percent) / 100))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns.
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            problem = L("GitHub didn't return yt-dlp (HTTP %d).", (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
            return
        }
        let kept = directory.appendingPathComponent(".yt-dlp.zip")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.moveItem(at: location, to: kept)
            archive = kept
        } catch {
            problem = error.localizedDescription
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task is URLSessionDownloadTask else { return }
        guard !isCancelled else { end(.idle); return }
        if let error { end(.failed(L("Download failed: %@", error.localizedDescription))); return }
        guard let archive, problem == nil else { end(.failed(problem ?? L("Download failed."))); return }
        guard let expected, (try? ManagedInstaller.sha256(of: archive)) == expected else {
            end(.failed(L("The download didn't match the published checksum, so it was discarded.")))
            return
        }
        report(.running(L("Unpacking yt-dlp…"), nil))
        try? FileManager.default.removeItem(at: unpacked)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, unpacked.path]
        let program = unpacked.appendingPathComponent(YTDLPRelease.executable).path
        // A semaphore, not waitUntilExit(): that spins this queue's empty run loop.
        let exited = DispatchSemaphore(value: 0)
        ditto.terminationHandler = { _ in exited.signal() }
        do {
            try ditto.run()
            exited.wait()
        } catch {
            end(.failed(error.localizedDescription))
            return
        }
        guard ditto.terminationStatus == 0, VideoTools.isExecutable(program) else {
            end(.failed(L("The downloaded yt-dlp didn't run.")))
            return
        }
        try? FileManager.default.removeItem(at: archive)
        self.archive = nil
        // The first launch includes macOS's one-time check of the new files (several seconds).
        report(.running(L("Checking the new yt-dlp…"), nil))
        DispatchQueue.main.async {
            VideoTools.readVersion(program) { version in
                guard let version, !self.isCancelled else { self.end(.failed(L("The downloaded yt-dlp didn't run."))); return }
                guard self.swapIntoPlace() else {
                    self.end(.failed(String(cString: strerror(errno))))
                    return
                }
                self.end(.finished(L("Installed yt-dlp %@.", version.description)))
            }
        }
    }

    /// One rename: a running download keeps the files it opened, a new one gets the new copy.
    private func swapIntoPlace() -> Bool {
        let target = VideoTools.managedFolder
        guard FileManager.default.fileExists(atPath: target.path) else { return rename(unpacked.path, target.path) == 0 }
        // The old copy ends up at `unpacked`, which end() removes.
        return renamex_np(unpacked.path, target.path, UInt32(RENAME_SWAP)) == 0
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Jobs

final class DownloadJob {
    enum State: Equatable {
        case queued, running, finishing, done, failed, cancelled
        var isActive: Bool { self == .queued || self == .running || self == .finishing }
    }

    let id = UUID()
    let url: String
    let preset: VideoPreset
    let folder: String
    let playlists: Bool
    var state = State.queued
    var title: String?
    var meter = DownloadMeter()
    /// Post-processing under way ("Merging video and audio…").
    var step: String?
    /// Finished files.
    var files: [String] = []
    /// Why it failed, or what went wrong in a playlist that still produced files.
    var message: String?
    var item: (index: Int, count: Int)?

    // While running.
    fileprivate var runner: LineProcess?
    fileprivate var remux: MediaRemux?
    fileprivate var started = Date()
    fileprivate var withoutFFmpeg = false
    fileprivate var stems: Set<String> = []
    fileprivate var merges: [(target: String, parts: [String])] = []
    fileprivate var dashAudio = false
    fileprivate var cancelling = false
    fileprivate var tail: [String] = []

    init(url: String, preset: VideoPreset, folder: String, playlists: Bool) {
        self.url = url
        self.preset = preset
        self.folder = folder
        self.playlists = playlists
    }

    var displayTitle: String { title ?? url }

    fileprivate func reset() {
        state = .queued
        meter = DownloadMeter()
        step = nil
        files = []
        message = nil
        item = nil
        stems = []
        merges = []
        dashAudio = false
        cancelling = false
        tail = []
    }
}

/// The download queue: at most two yt-dlp processes at a time; finished jobs are kept in memory
/// only (the last 20), so nothing about downloads is ever written to disk by BarTap itself.
final class VideoDownloads {
    static let shared = VideoDownloads()
    static let maxRunning = 2
    static let maxFinished = 20
    static var menuTitle: String { L("Download Video…") }
    static var defaultFolder: String { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path }

    /// AppDelegate's instance in the app (same defaults either way); a scratch one in headless runs.
    lazy var settings = Settings()
    /// Newest first.
    private(set) var jobs: [DownloadJob] = []
    private var panel: DownloadPanel?
    /// Tells the user a job ended; headless runs print instead.
    var announce: (DownloadJob) -> Void = { job in VideoDownloads.shared.toast(job) }

    var folder: String { settings.videoFolder.isEmpty ? Self.defaultFolder : settings.videoFolder }
    var panelIsVisible: Bool { panel?.isVisible ?? false }

    /// Opens the download panel (menu item "Download Video…"). `prefill` goes into the link field;
    /// without it, a link on the clipboard is offered (see DownloadPanel.present).
    func showPanel(prefill: String? = nil) {
        let p = panel ?? DownloadPanel(model: self)
        p.onClose = { [weak self] in
            self?.panel = nil
            Memory.returnFreedPages(after: 1.0)
        }
        panel = p
        VideoTools.shared.forgetInstallResult()
        VideoTools.shared.refresh()
        p.present(prefill: prefill)
    }

    @discardableResult
    func add(url: String, preset: VideoPreset) -> DownloadJob {
        if let same = jobs.first(where: { $0.url == url && $0.preset == preset && $0.state.isActive }) { return same }
        let job = DownloadJob(url: url, preset: preset, folder: folder, playlists: settings.videoPlaylists)
        jobs.insert(job, at: 0)
        let finished = jobs.filter { !$0.state.isActive }
        if finished.count > Self.maxFinished {
            let drop = Set(finished.suffix(finished.count - Self.maxFinished).map(\.id))
            jobs.removeAll { drop.contains($0.id) }
        }
        changed(nil)
        VideoTools.shared.refresh { [weak self] in self?.pump() }
        return job
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .queued:
            job.state = .cancelled
            changed(job)
        case .running:
            job.cancelling = true
            job.step = L("Cancelling…")
            changed(job)
            // Escalate only against this process: a quick Retry starts a new one.
            let runner = job.runner
            runner?.signal(SIGINT)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak runner] in runner?.signal(SIGTERM) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak runner] in runner?.signal(SIGKILL) }
        case .finishing:
            job.cancelling = true
            job.remux?.cancel()
        default:
            break
        }
    }

    func retry(_ job: DownloadJob) {
        guard !job.state.isActive else { return }
        job.reset()
        changed(job)
        VideoTools.shared.refresh { [weak self] in self?.pump() }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
        changed(nil)
    }

    func reveal(_ job: DownloadJob) {
        let existing = job.files.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if existing.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.folder, isDirectory: true))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    /// Queued jobs waited for a version check or an install.
    func toolsChanged() {
        if jobs.contains(where: { $0.state == .queued }) { pump() }
    }

    /// For headless renders only.
    func setJobsForPreview(_ list: [DownloadJob]) { jobs = list }

    /// yt-dlp's environment: the install folders on PATH (an app opened from Finder gets
    /// launchd's bare PATH) and unbuffered UTF-8 output, so progress arrives line by line.
    static func environment(includeInstallDirs: Bool = true) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolLocator.searchPath(inherited: env["PATH"], includeInstallDirs: includeInstallDirs)
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// For applicationWillTerminate: tells every yt-dlp (and its helpers) to stop, so none keeps
    /// running after BarTap quits.
    func stopAll() {
        for job in jobs where job.state == .running {
            job.cancelling = true
            job.runner?.signal(SIGINT)
        }
        jobs.forEach { $0.remux?.cancel() }
    }

    private var holdingTermination = false

    private func changed(_ job: DownloadJob?) {
        // Info.plist allows sudden termination; while something runs, macOS must ask first, so
        // logging out doesn't silently kill a download mid-file.
        let busy = jobs.contains { $0.state == .running || $0.state == .finishing }
        if busy != holdingTermination {
            holdingTermination = busy
            if busy { ProcessInfo.processInfo.disableSuddenTermination() } else { ProcessInfo.processInfo.enableSuddenTermination() }
        }
        NotificationCenter.default.post(name: .barTapDownloadsChanged, object: job)
    }

    // MARK: Running

    private func pump() {
        let busy = jobs.filter { $0.state == .running || $0.state == .finishing }.count
        guard busy < Self.maxRunning, let next = jobs.last(where: { $0.state == .queued }) else { return }
        let tools = VideoTools.shared
        guard let chain = tools.status.toolchain else {
            if tools.status.checking || tools.isInstalling { return }   // refresh/install calls back
            fail(next, tools.status.path == nil
                 ? L("yt-dlp isn't installed. Download it below, or in Settings › Power-ups.")
                 : L("yt-dlp didn't start. Choose another copy in Settings › Power-ups."))
            return
        }
        if let v = chain.version, v < YTDLPVersion.minimum {
            fail(next, L("This yt-dlp is too old for BarTap. Update it."))
            return
        }
        if next.preset.needsFFmpeg && chain.ffmpeg == nil {
            fail(next, L("MP3 needs ffmpeg: brew install ffmpeg"))
            return
        }
        start(next, chain)
        pump()
    }

    private func start(_ job: DownloadJob, _ tools: VideoToolchain) {
        let request = VideoRequest(url: job.url, preset: job.preset, folder: job.folder, playlists: job.playlists)
        let p = LineProcess(tools.ytdlp, VideoArguments.make(request, tools: tools),
                            environment: Self.environment(includeInstallDirs: !VideoTools.ignoreFFmpeg))
        job.state = .running
        job.started = Date()
        job.withoutFFmpeg = tools.ffmpeg == nil
        p.onLine = { [weak self, weak job] line, isError in
            guard let self, let job else { return }
            self.handle(line, isError: isError, job)
        }
        p.onExit = { [weak self, weak job] status in
            guard let self, let job else { return }
            self.ended(job, status: status)
        }
        job.runner = p
        do {
            try p.start()
        } catch {
            job.runner = nil
            fail(job, L("yt-dlp didn't start: %@", error.localizedDescription))
            return
        }
        changed(job)
    }

    private func handle(_ line: String, isError: Bool, _ job: DownloadJob) {
        if isError {
            job.tail.append(line)
            if job.tail.count > 40 { job.tail.removeFirst(job.tail.count - 40) }
        }
        guard let event = DownloadLine.parse(line), !job.cancelling else { return }
        switch event {
        case .begin(let item):
            job.meter.begin(item)
            if !item.title.isEmpty { job.title = item.title }
            if let i = item.playlistIndex, let n = item.playlistCount, n > 1 { job.item = (i, n) }
            job.stems.insert(Self.stemPath(item.filename))
            job.step = nil
        case .progress(let p):
            job.meter.update(p)
            job.step = nil
        case .step(let name, let finished):
            // Steps run back to back; the last one stays up until something else happens.
            if !finished, let title = Self.stepTitle(name, job.preset) { job.step = title }
        case .file(let path):
            job.files.append(path)
            job.stems.insert(Self.stemPath(path))
        case .parts(let paths):
            if let target = job.files.last { job.merges.append((target, paths)) }
        case .warning(let text):
            if text.contains("DASH m4a") { job.dashAudio = true }
        case .error:
            break
        }
        changed(job)
    }

    private static func stepTitle(_ postprocessor: String, _ preset: VideoPreset) -> String? {
        switch postprocessor {
        case "Merger": return L("Merging video and audio…")
        case "ExtractAudio": return preset == .mp3 ? L("Converting to MP3…") : L("Extracting audio…")
        case "MoveFiles": return nil
        default: return L("Finishing…")
        }
    }

    private static func stemPath(_ file: String) -> String {
        (file as NSString).deletingLastPathComponent + "/" + DownloadLeftovers.stem(of: file)
    }

    private func ended(_ job: DownloadJob, status: Int32) {
        job.runner = nil
        if job.cancelling { stop(job, as: .cancelled); return }
        if job.files.isEmpty {
            stop(job, as: .failed, DownloadErrorText.friendly(job.tail, exitCode: status))
            return
        }
        // A playlist can end with an error after some videos were saved.
        if status != 0 { job.message = DownloadErrorText.friendly(job.tail, exitCode: status) }
        finishWithoutFFmpeg(job)
    }

    /// Without ffmpeg, yt-dlp leaves video and audio as two files and YouTube audio in a DASH
    /// container; AVFoundation joins or rewrites them, copying samples (no re-encoding).
    private func finishWithoutFFmpeg(_ job: DownloadJob) {
        let fm = FileManager.default
        var work: [(inputs: [String], output: String)] = []
        if job.withoutFFmpeg {
            for m in job.merges where !fm.fileExists(atPath: m.target) && m.parts.allSatisfy(fm.fileExists(atPath:)) {
                work.append((m.parts, m.target))
            }
            if job.dashAudio {
                for f in job.files where f.lowercased().hasSuffix(".m4a") && fm.fileExists(atPath: f) { work.append(([f], f)) }
            }
        }
        guard !work.isEmpty else { complete(job); return }
        job.state = .finishing
        job.step = work.contains { $0.inputs.count > 1 } ? L("Merging video and audio…") : L("Finishing…")
        changed(job)
        func next(_ i: Int) {
            guard i < work.count else { complete(job); return }
            let remux = MediaRemux()
            job.remux = remux
            let w = work[i]
            remux.run(w.inputs.map { URL(fileURLWithPath: $0) }, into: URL(fileURLWithPath: w.output)) { [weak self] error in
                guard let self else { return }
                job.remux = nil
                if job.cancelling { self.stop(job, as: .cancelled); return }
                if let error {
                    // Keep what was downloaded; the separate files still play on their own.
                    job.message = L("Couldn't merge video and audio without ffmpeg (%@). Install it: brew install ffmpeg", error.localizedDescription)
                    if w.inputs.count > 1, let i = job.files.firstIndex(of: w.output) { job.files.replaceSubrange(i...i, with: w.inputs) }
                } else if w.inputs.count > 1 {
                    w.inputs.forEach { try? fm.removeItem(atPath: $0) }
                }
                next(i + 1)
            }
        }
        next(0)
    }

    private func complete(_ job: DownloadJob) {
        job.state = .done
        job.step = nil
        changed(job)
        announce(job)
        pump()
    }

    private func fail(_ job: DownloadJob, _ message: String) {
        stop(job, as: .failed, message)
    }

    private func stop(_ job: DownloadJob, as state: DownloadJob.State, _ message: String? = nil) {
        job.state = state
        job.message = message
        job.step = nil
        removeLeftovers(job)
        changed(job)
        if state == .failed { announce(job) }
        pump()
    }

    /// Removes what this job left half-done (".part", ".ytdl", unmerged ".f137.mp4" streams,
    /// ".temp." files), and nothing that existed before it started.
    private func removeLeftovers(_ job: DownloadJob) {
        let fm = FileManager.default
        let keep = Set(job.files)
        for dir in Set(job.stems.map { ($0 as NSString).deletingLastPathComponent }) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let files = names.compactMap { name -> (name: String, created: Date)? in
                let path = dir + "/" + name
                guard !keep.contains(path), let created = (try? fm.attributesOfItem(atPath: path))?[.creationDate] as? Date else { return nil }
                return (name, created)
            }
            let stems = Set(job.stems.filter { ($0 as NSString).deletingLastPathComponent == dir }.map { ($0 as NSString).lastPathComponent })
            let keepNames = Set(keep.filter { ($0 as NSString).deletingLastPathComponent == dir }.map { ($0 as NSString).lastPathComponent })
            for name in DownloadLeftovers.select(files, stems: stems, keep: keepNames, since: job.started) {
                try? fm.removeItem(atPath: dir + "/" + name)
            }
        }
    }

    private func toast(_ job: DownloadJob) {
        guard !panelIsVisible else { return }
        let title = job.displayTitle.count > 48 ? String(job.displayTitle.prefix(47)) + "…" : job.displayTitle
        switch job.state {
        case .done: Toast.show(L("Downloaded %@", title), symbol: "arrow.down.circle")
        case .failed: Toast.show(L("Download failed: %@", title), symbol: "exclamationmark.triangle")
        default: break
        }
    }
}

// MARK: - Joining streams without ffmpeg

/// Copies samples into one file without re-encoding. YouTube's DASH files declare their length
/// in the header *and* in their fragments; AVFoundation adds both and would stretch the last
/// frame over a second, empty half. So zero-sample marker buffers are dropped and the movie
/// ends at the last real sample.
final class MediaRemux: @unchecked Sendable {   // `cancelled` is behind a lock
    enum Failure: LocalizedError {
        case noTracks, cancelled, failed(String)
        var errorDescription: String? {
            switch self {
            case .noTracks: return L("no audio or video found")
            case .cancelled: return L("Cancelled")
            case .failed(let why): return why
            }
        }
    }

    /// State of one copy. After setup it is only touched on the writer's serial queue.
    private final class Run: @unchecked Sendable {
        let writer: AVAssetWriter
        var end = CMTime.zero
        var error: Error?
        var open = 0
        init(writer: AVAssetWriter) { self.writer = writer }
    }

    /// One track being copied. The lane keeps its reader alive: outputs only hold it weakly.
    private final class Lane: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var open = true
        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.reader = reader; self.output = output; self.input = input
        }
    }

    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Writes to "<stem>.temp.<ext>" next to `output`, then moves it into place (replacing
    /// `output` when one input is being rewritten in place). Completion runs on the main queue.
    func run(_ inputs: [URL], into output: URL, completion: @escaping (Error?) -> Void) {
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(DownloadLeftovers.stem(of: output.lastPathComponent) + ".temp." + output.pathExtension)
        let type: AVFileType = output.pathExtension.lowercased() == "m4a" ? .m4a : output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        Task {
            var failure: Error?
            do {
                try? FileManager.default.removeItem(at: temp)
                try await self.copy(inputs, to: temp, type: type)
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: output)
                }
            } catch {
                failure = error
                try? FileManager.default.removeItem(at: temp)
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    private func copy(_ inputs: [URL], to out: URL, type: AVFileType) async throws {
        // Video from the first input that has it; audio preferably from an audio-only input.
        var video: (AVURLAsset, AVAssetTrack)?
        var audio: (AVURLAsset, AVAssetTrack, alone: Bool)?
        for url in inputs {
            let asset = AVURLAsset(url: url)
            let v = try await asset.loadTracks(withMediaType: .video).first
            let a = try await asset.loadTracks(withMediaType: .audio).first
            if video == nil, let v { video = (asset, v) }
            if let a, audio == nil || (v == nil && audio?.alone == false) { audio = (asset, a, v == nil) }
        }
        let picked = [video, audio.map { ($0.0, $0.1) }].compactMap { $0 }
        guard !picked.isEmpty else { throw Failure.noTracks }

        let writer = try AVAssetWriter(outputURL: out, fileType: type)
        writer.shouldOptimizeForNetworkUse = true   // index first, like ffmpeg's +faststart
        var readers: [ObjectIdentifier: AVAssetReader] = [:]
        var lanes: [Lane] = []
        for (asset, track) in picked {
            let reader = try readers[ObjectIdentifier(asset)] ?? AVAssetReader(asset: asset)
            readers[ObjectIdentifier(asset)] = reader
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let hint = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(output), writer.canAdd(input) else { throw Failure.failed(L("unsupported format")) }
            reader.add(output)
            writer.add(input)
            lanes.append(Lane(reader: reader, output: output, input: input))
        }
        for reader in readers.values where !reader.startReading() {
            throw reader.error ?? Failure.failed(L("unreadable file"))
        }
        guard writer.startWriting() else { throw writer.error ?? Failure.failed(L("can't write the file")) }
        writer.startSession(atSourceTime: .zero)
        let run = Run(writer: writer)
        run.open = lanes.count
        do {
            let end: CMTime = try await withCheckedThrowingContinuation { continuation in
                let queue = DispatchQueue(label: "BarTap.remux")
                for lane in lanes {
                    lane.input.requestMediaDataWhenReady(on: queue) {
                        while lane.open && lane.input.isReadyForMoreMediaData {
                            if run.error == nil && self.isCancelled { run.error = Failure.cancelled }
                            guard run.error == nil, let sample = lane.output.copyNextSampleBuffer() else {
                                if run.error == nil && lane.reader.status == .failed {
                                    run.error = lane.reader.error ?? Failure.failed(L("unreadable file"))
                                }
                                lane.open = false
                                lane.input.markAsFinished()
                                run.open -= 1
                                if run.open == 0 {
                                    if let error = run.error { continuation.resume(throwing: error) } else { continuation.resume(returning: run.end) }
                                }
                                return
                            }
                            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                            guard lane.input.append(sample) else {
                                run.error = run.writer.error ?? Failure.failed(L("can't write the file"))
                                continue
                            }
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample), duration = CMSampleBufferGetDuration(sample)
                            let last = duration.isValid ? CMTimeAdd(pts, duration) : pts
                            if last.isValid && CMTimeCompare(last, run.end) > 0 { run.end = last }
                        }
                    }
                }
            }
            writer.endSession(atSourceTime: end)
            await writer.finishWriting()
        } catch {
            lanes.forEach { $0.reader.cancelReading() }
            writer.cancelWriting()
            throw error
        }
        guard writer.status == .completed else { throw writer.error ?? Failure.failed(L("can't write the file")) }
    }
}
