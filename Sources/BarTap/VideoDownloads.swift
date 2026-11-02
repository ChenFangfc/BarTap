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
    /// Keep stdout whole instead of splitting it into lines (a JSON document); stderr still
    /// arrives line by line. Capped, so a runaway program can't fill memory.
    var collectsOutput = false
    private(set) var output = Data()
    private static let maxOutput = 64 * 1024 * 1024

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
        if stream == 0 && collectsOutput {
            lock.lock()
            if output.count + data.count <= Self.maxOutput { output.append(data) }
            lock.unlock()
            if data.isEmpty { group.leave() }
            return
        }
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

    /// For Settings › Download component: "2026.10.26", "2026.03.17 · Homebrew", "Not installed".
    var statusLine: String {
        let s = status
        guard s.path != nil else { return lookedUp ? L("Not installed") : L("Checking…") }
        guard let v = s.version else { return s.checking ? L("Checking…") : L("Doesn't start") }
        switch s.source {
        case .homebrew?: return "\(v) · Homebrew"
        case .custom?: return "\(v) · " + L("Chosen by you")
        case .external?: return "\(v) · " + L("Installed separately")
        default: return v.description
        }
    }

    /// What is missing or old, most important first; empty when all is well.
    var problems: [String] {
        guard status.path != nil, let v = status.version else { return [] }
        var p: [String] = []
        if v < YTDLPVersion.minimum {
            p.append(L("Too old for BarTap. Update it."))
        } else if v.isStale() {
            p.append(L("Over 3 months old. Update it if downloads fail."))
        }
        if v.hasJSRuntimes && status.js == nil { p.append(L("For YouTube, install Deno: brew install deno")) }
        if status.ffmpeg == nil { p.append(L("For HD video, MP3 and extras, install ffmpeg: brew install ffmpeg")) }
        return p
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
        report(.running(L("Checking for updates…"), nil))
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
            end(.failed(error.map { L("Couldn't reach GitHub: %@", $0.localizedDescription) } ?? L("Couldn't read the release checksums.")))
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
                    self.end(.finished(L("Already up to date.")))
                    return
                }
                self.report(.running(L("Downloading %@…", self.tag ?? ""), 0))
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
        report(.running(L("Downloading %@…", tag ?? ""), Double(percent) / 100))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns.
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            problem = L("GitHub didn't return the download (HTTP %d).", (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)
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
            end(.failed(L("The download didn't match its published checksum and was discarded.")))
            return
        }
        report(.running(L("Unpacking…"), nil))
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
            end(.failed(L("The new version didn't run.")))
            return
        }
        try? FileManager.default.removeItem(at: archive)
        self.archive = nil
        // The first launch includes macOS's one-time check of the new files (several seconds).
        report(.running(L("Checking the new version…"), nil))
        DispatchQueue.main.async {
            VideoTools.readVersion(program) { version in
                guard let version, !self.isCancelled else { self.end(.failed(L("The new version didn't run."))); return }
                guard self.swapIntoPlace() else {
                    self.end(.failed(String(cString: strerror(errno))))
                    return
                }
                self.end(.finished(L("Installed %@.", version.description)))
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
        case queued, running, finishing, paused, done, failed, cancelled
        /// Waiting or working; a paused job is neither.
        var isActive: Bool { self == .queued || self == .running || self == .finishing }
        var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
    }

    let id = UUID()
    let request: VideoRequest
    var url: String { request.url }
    var folder: String { request.folder }
    var state = State.queued
    var title: String?
    /// From the panel's preview, already scaled down.
    var thumbnail: NSImage?
    var meter = DownloadMeter()
    /// Post-processing under way ("Merging video and audio…").
    var step: String?
    /// Finished files.
    var files: [String] = []
    /// Why it failed, or what went wrong in a playlist that still produced files.
    var message: String?
    var item: (index: Int, count: Int)?
    /// The file was already in the folder; nothing was downloaded.
    var alreadyThere = false

    // While running.
    fileprivate var runner: LineProcess?
    fileprivate var remux: MediaRemux?
    /// The first start: pausing and resuming keep it, so clean-up still knows this job's files.
    fileprivate var firstStarted: Date?
    fileprivate var withoutFFmpeg = false
    fileprivate var stems: Set<String> = []
    fileprivate var merges: [(target: String, parts: [String])] = []
    fileprivate var dashAudio = false
    fileprivate var cancelling = false
    fileprivate var pausing = false
    fileprivate var sawProgress = false
    fileprivate var tail: [String] = []

    init(request: VideoRequest, title: String? = nil, thumbnail: NSImage? = nil) {
        self.request = request
        self.title = title
        self.thumbnail = thumbnail
    }

    var displayTitle: String { title ?? url }

    /// Before running again; `fresh` also forgets the first start (after Cancel or a failure,
    /// whose files were removed).
    fileprivate func reset(fresh: Bool) {
        state = .queued
        meter = DownloadMeter()
        step = nil
        files = []
        message = nil
        item = nil
        alreadyThere = false
        merges = []
        dashAudio = false
        cancelling = false
        pausing = false
        sawProgress = false
        tail = []
        if fresh {
            firstStarted = nil
            stems = []
        }
    }
}

/// The download queue: at most two downloads at a time; finished jobs are kept in memory only
/// (the last 20), so nothing about downloads is ever written to disk by BarTap itself.
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

    /// Opens the download panel (menu item "Download Video…"). `prefill` goes into the link
    /// field and its details are fetched right away.
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

    /// Remembers where the user saves, for the panel's Save to menu.
    func choose(folder path: String) {
        settings.videoFolder = path == Self.defaultFolder ? "" : path
        settings.videoRecentFolders = RecentFolders.adding(path, to: settings.videoRecentFolders)
    }

    /// A download with the user's current choices; the quality is the default one.
    func request(url: String, quality: VideoQuality? = nil) -> VideoRequest {
        VideoRequest(url: url, quality: quality ?? settings.videoQuality, folder: folder, options: settings.videoOptions)
    }

    @discardableResult
    func add(_ request: VideoRequest, title: String? = nil, thumbnail: NSImage? = nil) -> DownloadJob {
        if let same = jobs.first(where: { $0.request == request && ($0.state.isActive || $0.state == .paused) }) { return same }
        let job = DownloadJob(request: request, title: title, thumbnail: thumbnail)
        jobs.insert(job, at: 0)
        let finished = jobs.filter { $0.state.isFinished }
        if finished.count > Self.maxFinished {
            let drop = Set(finished.suffix(finished.count - Self.maxFinished).map(\.id))
            jobs.removeAll { drop.contains($0.id) }
        }
        changed(nil)
        VideoTools.shared.refresh { [weak self] in self?.pump() }
        return job
    }

    /// Stops the download but keeps what arrived; Resume continues the partial file.
    func pause(_ job: DownloadJob) {
        guard job.state == .running, !job.cancelling else { return }
        job.pausing = true
        job.step = L("Pausing…")
        changed(job)
        interrupt(job)
    }

    func resume(_ job: DownloadJob) {
        guard job.state == .paused else { return }
        job.reset(fresh: false)
        changed(job)
        VideoTools.shared.refresh { [weak self] in self?.pump() }
    }

    func cancel(_ job: DownloadJob) {
        switch job.state {
        case .queued:
            job.state = .cancelled
            changed(job)
        case .paused:
            job.cancelling = true
            stop(job, as: .cancelled)
        case .running:
            job.cancelling = true
            job.pausing = false
            job.step = L("Cancelling…")
            changed(job)
            interrupt(job)
        case .finishing:
            job.cancelling = true
            job.remux?.cancel()
        default:
            break
        }
    }

    /// SIGINT first, like ⌃C in Terminal; escalation only against this process (a quick
    /// Resume or Retry starts a new one).
    private func interrupt(_ job: DownloadJob) {
        let runner = job.runner
        runner?.signal(SIGINT)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak runner] in runner?.signal(SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak runner] in runner?.signal(SIGKILL) }
    }

    func retry(_ job: DownloadJob) {
        guard job.state.isFinished else { return }
        job.reset(fresh: true)
        changed(job)
        VideoTools.shared.refresh { [weak self] in self?.pump() }
    }

    func remove(_ job: DownloadJob) {
        guard job.state.isFinished else { return }
        jobs.removeAll { $0 === job }
        changed(nil)
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
        changed(nil)
    }

    func reveal(_ job: DownloadJob) {
        let existing = existingFiles(job)
        if existing.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.folder, isDirectory: true))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }

    func open(_ job: DownloadJob) {
        guard let first = existingFiles(job).first else { reveal(job); return }
        NSWorkspace.shared.open(first)
    }

    func existingFiles(_ job: DownloadJob) -> [URL] {
        job.files.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Queued jobs waited for a version check or an install.
    func toolsChanged() {
        if jobs.contains(where: { $0.state == .queued }) { pump() }
    }

    /// For headless renders only.
    func setJobsForPreview(_ list: [DownloadJob]) { jobs = list }

    /// The component's environment: the install folders on PATH (an app opened from Finder gets
    /// launchd's bare PATH) and unbuffered UTF-8 output, so progress arrives line by line.
    static func environment(includeInstallDirs: Bool = true) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolLocator.searchPath(inherited: env["PATH"], includeInstallDirs: includeInstallDirs)
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    /// For applicationWillTerminate: tells every download (and its helpers) to stop, so none
    /// keeps running after BarTap quits. Partial files stay; the same download later resumes them.
    func stopAll() {
        for job in jobs where job.state == .running {
            job.pausing = true
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

    // MARK: Details

    /// Fetches a link's details (`-J`); `done` runs on the main queue unless cancelled.
    final class InfoFetch {
        fileprivate var runner: LineProcess?
        fileprivate(set) var cancelled = false
        func cancel() {
            cancelled = true
            runner?.signal(SIGTERM)
        }
    }

    @discardableResult
    func fetchInfo(url: String, browser: CookieBrowser?, done: @escaping (Result<VideoInfo, InfoError>) -> Void) -> InfoFetch {
        let fetch = InfoFetch()
        VideoTools.shared.refresh {
            guard !fetch.cancelled else { return }
            guard let chain = VideoTools.shared.status.toolchain else {
                done(.failure(InfoError(VideoTools.shared.status.path == nil ? L("The download component isn't installed.") : L("The download component doesn't start."))))
                return
            }
            let p = LineProcess(chain.ytdlp, VideoArguments.info(url: url, tools: chain, browser: browser),
                                environment: Self.environment(includeInstallDirs: !VideoTools.ignoreFFmpeg))
            p.collectsOutput = true
            var tail: [String] = []
            p.onLine = { line, isError in
                guard isError else { return }
                tail.append(line)
                if tail.count > 40 { tail.removeFirst() }
            }
            p.onExit = { status in
                fetch.runner = nil
                guard !fetch.cancelled else { return }
                if status == 0, let info = VideoInfo.parse(p.output) {
                    done(.success(info))
                } else {
                    done(.failure(InfoError(DownloadErrorText.friendly(tail, exitCode: status))))
                }
            }
            fetch.runner = p
            do { try p.start() } catch { done(.failure(InfoError(error.localizedDescription))) }
        }
        return fetch
    }

    struct InfoError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: Running

    private func pump() {
        let busy = jobs.filter { $0.state == .running || $0.state == .finishing }.count
        guard busy < Self.maxRunning, let next = jobs.last(where: { $0.state == .queued }) else { return }
        let tools = VideoTools.shared
        guard let chain = tools.status.toolchain else {
            if tools.status.checking || tools.isInstalling { return }   // refresh/install calls back
            fail(next, tools.status.path == nil ? L("The download component isn't installed.") : L("The download component doesn't start."))
            return
        }
        if let v = chain.version, v < YTDLPVersion.minimum {
            fail(next, L("The download component is too old. Update it."))
            return
        }
        let r = next.request
        if r.quality.isAudio && r.options.audioFormat != .m4a && chain.ffmpeg == nil {
            fail(next, L("MP3 and Opus need ffmpeg: brew install ffmpeg"))
            return
        }
        start(next, chain)
        pump()
    }

    private func start(_ job: DownloadJob, _ tools: VideoToolchain) {
        let args = VideoArguments.make(job.request, tools: tools, preferredLanguage: Locale.preferredLanguages.first ?? "en")
        let p = LineProcess(tools.ytdlp, args, environment: Self.environment(includeInstallDirs: !VideoTools.ignoreFFmpeg))
        job.state = .running
        if job.firstStarted == nil { job.firstStarted = Date() }
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
            fail(job, L("The download component doesn't start: %@", error.localizedDescription))
            return
        }
        changed(job)
    }

    private func handle(_ line: String, isError: Bool, _ job: DownloadJob) {
        if isError {
            job.tail.append(line)
            if job.tail.count > 40 { job.tail.removeFirst(job.tail.count - 40) }
        }
        guard let event = DownloadLine.parse(line), !job.cancelling, !job.pausing else { return }
        switch event {
        case .begin(let item):
            job.meter.begin(item)
            if !item.title.isEmpty { job.title = item.title }
            if let i = item.playlistIndex, let n = item.playlistCount, n > 1 { job.item = (i, n) }
            job.stems.insert(Self.stemPath(item.filename))
            job.step = nil
        case .progress(let p):
            job.meter.update(p)
            job.sawProgress = true
            job.step = nil
        case .step(let name, let finished):
            // Steps run back to back; the last one stays up until something else happens.
            if !finished, let title = Self.stepTitle(name, job.request) { job.step = title }
        case .file(let path):
            job.files.append(path)
            job.stems.insert(Self.stemPath(path))
            // Nothing downloaded and the file predates the job: it was already in the folder.
            if !job.sawProgress, let created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date,
               let first = job.firstStarted, created < first {
                job.alreadyThere = true
            }
        case .parts(let paths):
            if let target = job.files.last { job.merges.append((target, paths)) }
        case .warning(let text):
            if text.contains("DASH m4a") { job.dashAudio = true }
            // Errors that --ignore-errors turned into warnings: the video still comes.
            if text.contains("Unable to download video subtitles") { job.message = L("Some subtitles couldn't be downloaded.") }
        case .error:
            break
        }
        changed(job)
    }

    private static func stepTitle(_ postprocessor: String, _ r: VideoRequest) -> String? {
        switch postprocessor {
        case "Merger": return L("Merging video and audio…")
        case "ExtractAudio":
            return r.options.audioFormat == .m4a ? L("Extracting audio…") : L("Converting to %@…", r.options.audioFormat.title)
        case "EmbedSubtitle": return L("Adding subtitles…")
        case "ModifyChapters": return L("Removing sponsor segments…")
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
        if job.pausing {
            // Keep everything: the next start continues the partial files.
            job.pausing = false
            job.state = .paused
            job.step = nil
            changed(job)
            pump()
            return
        }
        if job.files.isEmpty {
            stop(job, as: .failed, DownloadErrorText.friendly(job.tail, exitCode: status))
            return
        }
        // A playlist can end with an error after some videos were saved.
        if status != 0 { job.message = DownloadErrorText.friendly(job.tail, exitCode: status) }
        finishWithoutFFmpeg(job)
    }

    /// Without ffmpeg, video and audio arrive as two files and YouTube audio in a DASH
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
    /// ".temp." files), and nothing that existed before it first started.
    private func removeLeftovers(_ job: DownloadJob) {
        guard let since = job.firstStarted else { return }
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
            for name in DownloadLeftovers.select(files, stems: stems, keep: keepNames, since: since) {
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
