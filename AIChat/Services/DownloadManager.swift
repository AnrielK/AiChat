import Foundation
import Observation
import os

/// Jedno stahování modelu (GGUF = 1 soubor, MLX = celá složka souborů).
/// Ukládá se do Application Support, takže přežije ukončení appky.
struct DownloadJob: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case downloading, installing, failed
    }

    struct File: Codable, Hashable, Sendable {
        let path: String
        let url: URL
        let size: Int64
    }

    let id: UUID
    /// Cílové ID modelu (`LocalModelFile.id`) – název .gguf nebo "mlx:<složka>".
    let modelID: String
    let kind: LocalModelKind
    let title: String
    let files: [File]
    var completed: Set<String> = []
    var state: State = .downloading
    var errorMessage: String?
}

/// Ke které úloze a souboru patří URLSession task (uloženo v `taskDescription`).
struct DownloadTaskInfo: Codable, Sendable {
    let jobID: UUID
    let path: String

    init(jobID: UUID, path: String) {
        self.jobID = jobID
        self.path = path
    }

    init?(_ description: String?) {
        guard let data = description?.data(using: .utf8),
              let value = try? JSONDecoder().decode(DownloadTaskInfo.self, from: data) else { return nil }
        self = value
    }

    var encoded: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Stahování přes background URLSession – pokračuje, i když je appka na pozadí nebo ji systém uspí.
/// Po znovuspuštění se úlohy dohledají (`reconcile`) a nedokončené soubory se znovu zařadí.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "AIChat") + ".downloads"
    private static let cellularKey = "downloads.allowCellular"

    private(set) var jobs: [DownloadJob] = []
    /// Modely, u kterých se teprve zjišťuje seznam souborů / velikost.
    private(set) var preparing: Set<String> = []
    var lastError: String?

    /// Nové úlohy se vypnutými mobilními daty počkají na Wi-Fi.
    var allowCellular: Bool {
        didSet { UserDefaults.standard.set(allowCellular, forKey: Self.cellularKey) }
    }

    private var received: [UUID: [String: Int64]] = [:]
    private var expected: [UUID: [String: Int64]] = [:]

    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?
    /// Zavolá se po instalaci modelu (ModelManager si obnoví seznam).
    @ObservationIgnored var onInstalled: (() -> Void)?
    @ObservationIgnored private let session: URLSession

    var activeCount: Int { jobs.filter { $0.state != .failed }.count }

    private init() {
        allowCellular = UserDefaults.standard.bool(forKey: Self.cellularKey)

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration, delegate: DownloadSessionDelegate(), delegateQueue: nil)

        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: ModelPaths.jobsFile),
           let saved = try? JSONDecoder().decode([DownloadJob].self, from: data) {
            jobs = saved
        }
        Task { await reconcile() }
    }

    // MARK: - Veřejné API

    func job(for modelID: String) -> DownloadJob? {
        jobs.first { $0.modelID == modelID }
    }

    func isBusy(_ modelID: String) -> Bool {
        preparing.contains(modelID) || job(for: modelID) != nil
    }

    func start(_ item: CatalogModel) {
        switch item.kind {
        case .gguf:
            if let url = URL(string: item.source) { startGGUF(url: url, title: item.name) }
        case .mlx:
            startMLX(repo: item.source, title: item.name)
        }
    }

    /// Vlastní odkaz: přímý odkaz na .gguf, nebo ID/odkaz MLX repozitáře.
    func start(custom input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".gguf") || text.contains("/resolve/") {
            guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
                lastError = "Neplatný odkaz."
                return
            }
            startGGUF(url: url, title: nil)
        } else if let repo = HuggingFaceRepo.normalizedID(text) {
            startMLX(repo: repo, title: nil)
        } else {
            lastError = "Zadej přímý odkaz na soubor .gguf, nebo ID MLX repozitáře (např. mlx-community/Qwen3-4B-4bit)."
        }
    }

    func startGGUF(url: URL, title: String?, knownSize: Int64? = nil) {
        let fileName = url.lastPathComponent
        guard fileName.lowercased().hasSuffix(".gguf") else {
            lastError = "Odkaz musí vést přímo na soubor .gguf (na Hugging Face tlačítko „download“ u souboru)."
            return
        }
        guard !isBusy(fileName) else { return }
        preparing.insert(fileName)

        Task {
            defer { _ = preparing.remove(fileName) }
            let size: Int64
            if let knownSize, knownSize > 0 {
                size = knownSize
            } else {
                size = await HuggingFaceRepo.remoteSize(of: url) ?? 0
            }
            // MoE modely mají klidně 18 GB – ať stahování nespadne v půlce na plném úložišti.
            guard DeviceMemory.hasStorage(for: size) else {
                let needed = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                let free = DeviceMemory.freeStorage.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
                lastError = "Na úložišti není dost místa: model má \(needed), volných je \(free)."
                return
            }
            add(DownloadJob(
                id: UUID(),
                modelID: fileName,
                kind: .gguf,
                title: title ?? LocalModelFile.displayName(forID: fileName),
                files: [DownloadJob.File(path: fileName, url: url, size: size)]
            ))
        }
    }

    func startMLX(repo: String, title: String?) {
        let folder = ModelPaths.mlxFolderName(repo: repo)
        let modelID = "mlx:" + folder
        guard !isBusy(modelID) else { return }
        preparing.insert(modelID)

        Task {
            defer { _ = preparing.remove(modelID) }
            do {
                let files = try await HuggingFaceRepo.files(repo: repo)
                guard files.contains(where: { $0.path.hasSuffix(".safetensors") }),
                      files.contains(where: { $0.path == "config.json" }) else {
                    throw ProviderError.notConfigured("\(repo) není MLX model (chybí config.json nebo *.safetensors).")
                }
                let jobFiles = files.compactMap { file in
                    HuggingFaceRepo.fileURL(repo: repo, path: file.path)
                        .map { DownloadJob.File(path: file.path, url: $0, size: file.size) }
                }
                add(DownloadJob(
                    id: UUID(),
                    modelID: modelID,
                    kind: .mlx,
                    title: title ?? LocalModelFile.displayName(forID: modelID),
                    files: jobFiles
                ))
            } catch {
                lastError = "Stažení \(repo) nejde spustit: \(error.localizedDescription)"
            }
        }
    }

    func cancel(_ job: DownloadJob) {
        let session = self.session
        Task {
            for task in await session.allTasks where DownloadTaskInfo(task.taskDescription)?.jobID == job.id {
                task.cancel()
            }
        }
        jobs.removeAll { $0.id == job.id }
        received[job.id] = nil
        expected[job.id] = nil
        save()
        try? FileManager.default.removeItem(at: ModelPaths.staging(for: job.id))
    }

    func retry(_ job: DownloadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].state = .downloading
        jobs[index].errorMessage = nil
        save()
        Task {
            let running = await runningPaths(for: job.id)
            guard let current = jobs.first(where: { $0.id == job.id }) else { return }
            let missing = current.files.map(\.path).filter { !current.completed.contains($0) && !running.contains($0) }
            enqueue(current, paths: missing)
        }
    }

    // MARK: - Průběh

    func totalBytes(_ job: DownloadJob) -> Int64 {
        job.files.reduce(Int64(0)) { sum, file in
            sum + max(file.size, expected[job.id]?[file.path] ?? 0)
        }
    }

    func bytesReceived(_ job: DownloadJob) -> Int64 {
        job.files.reduce(Int64(0)) { sum, file in
            if job.completed.contains(file.path) {
                return sum + max(file.size, expected[job.id]?[file.path] ?? 0)
            }
            return sum + (received[job.id]?[file.path] ?? 0)
        }
    }

    /// nil = celková velikost zatím neznámá.
    func fraction(_ job: DownloadJob) -> Double? {
        let total = totalBytes(job)
        guard total > 0 else { return nil }
        return min(1, Double(bytesReceived(job)) / Double(total))
    }

    /// Souhrn pro Nastavení: „Stahuji · 45 %“, „Stahuji 2 · 45 %“. nil = nic se nestahuje.
    var progressSummary: String? {
        let active = jobs.filter { $0.state != .failed }
        guard !active.isEmpty else {
            return jobs.isEmpty ? nil : "Stahování selhalo"
        }
        if active.allSatisfy({ $0.state == .installing }) { return "Instaluji…" }
        let label = active.count == 1 ? "Stahuji" : "Stahuji \(active.count)"
        let total = active.reduce(Int64(0)) { $0 + totalBytes($1) }
        guard total > 0 else { return label + "…" }
        let done = active.reduce(Int64(0)) { $0 + bytesReceived($1) }
        return "\(label) · \(Int(min(1, Double(done) / Double(total)) * 100)) %"
    }

    // MARK: - Události z delegáta (na hlavním vlákně)

    fileprivate func didWrite(_ info: DownloadTaskInfo, written: Int64, expectedTotal: Int64) {
        guard jobs.contains(where: { $0.id == info.jobID }) else { return }
        received[info.jobID, default: [:]][info.path] = written
        if expectedTotal > 0 {
            expected[info.jobID, default: [:]][info.path] = expectedTotal
        }
    }

    fileprivate func didFinish(_ info: DownloadTaskInfo) {
        guard let index = jobs.firstIndex(where: { $0.id == info.jobID }) else { return }
        jobs[index].completed.insert(info.path)
        received[info.jobID]?[info.path] = nil
        save()
        if jobs[index].completed.count >= jobs[index].files.count {
            install(jobs[index])
        }
    }

    fileprivate func didFail(_ info: DownloadTaskInfo, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == info.jobID }) else { return }
        received[info.jobID]?[info.path] = nil
        jobs[index].state = .failed
        jobs[index].errorMessage = message
        save()
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    // MARK: - Interní

    private func add(_ job: DownloadJob) {
        jobs.append(job)
        save()
        enqueue(job, paths: job.files.map(\.path))
    }

    private func enqueue(_ job: DownloadJob, paths: [String]) {
        for path in paths {
            guard let file = job.files.first(where: { $0.path == path }) else { continue }
            var request = HuggingFaceRepo.request(file.url)
            request.allowsCellularAccess = allowCellular
            let task = session.downloadTask(with: request)
            task.taskDescription = DownloadTaskInfo(jobID: job.id, path: path).encoded
            if file.size > 0 { task.countOfBytesClientExpectsToReceive = file.size }
            task.resume()
        }
    }

    private func install(_ job: DownloadJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].state = .installing
        do {
            try Self.moveIntoLibrary(job)
            jobs.removeAll { $0.id == job.id }
            received[job.id] = nil
            expected[job.id] = nil
            onInstalled?()
        } catch {
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].state = .failed
                jobs[index].errorMessage = "Instalace selhala: \(error.localizedDescription)"
            }
        }
        save()
    }

    /// Z dočasné složky úlohy do Models (GGUF) nebo Models/MLX/<složka> (MLX).
    private static func moveIntoLibrary(_ job: DownloadJob) throws {
        let fileManager = FileManager.default
        let staging = ModelPaths.staging(for: job.id)
        let source: URL
        let destination: URL

        switch job.kind {
        case .gguf:
            guard let file = job.files.first else { return }
            source = staging.appending(path: file.path)
            destination = ModelPaths.root.appending(path: job.modelID)
        case .mlx:
            source = staging
            destination = ModelPaths.mlx.appending(path: String(job.modelID.dropFirst(4)), directoryHint: .isDirectory)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        try? fileManager.removeItem(at: staging)
    }

    private func runningPaths(for jobID: UUID) async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { DownloadTaskInfo($0.taskDescription) }.filter { $0.jobID == jobID }.map(\.path))
    }

    /// Po znovuspuštění: převzít dokončené soubory, znovu zařadit, co systém zahodil, uklidit sirotky.
    private func reconcile() async {
        let tasks = await session.allTasks
        let running = Set(tasks.compactMap { DownloadTaskInfo($0.taskDescription) }.map { "\($0.jobID.uuidString)/\($0.path)" })
        let fileManager = FileManager.default

        let known = Set(jobs.map(\.id.uuidString))
        let folders = (try? fileManager.contentsOfDirectory(at: ModelPaths.stagingRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !known.contains(folder.lastPathComponent) {
            try? fileManager.removeItem(at: folder)
        }

        for job in jobs {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            let staging = ModelPaths.staging(for: job.id)
            for file in job.files where fileManager.fileExists(atPath: staging.appending(path: file.path).path(percentEncoded: false)) {
                jobs[index].completed.insert(file.path)
            }
            if jobs[index].state == .installing { jobs[index].state = .downloading }

            let current = jobs[index]
            if current.completed.count >= current.files.count {
                install(current)
                continue
            }
            guard current.state == .downloading else { continue }
            let missing = current.files.map(\.path).filter {
                !current.completed.contains($0) && !running.contains("\(current.id.uuidString)/\($0)")
            }
            enqueue(current, paths: missing)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: ModelPaths.jobsFile, options: .atomic)
        }
    }
}

/// Delegát background session – běží na vlákně URLSession, stav mění přes hlavní vlákno.
final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lastReport = OSAllocatedUnfairLock(initialState: [Int: Date]())

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let info = DownloadTaskInfo(downloadTask.taskDescription) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = HuggingFaceRepo.message(forStatus: http.statusCode)
            Task { @MainActor in DownloadManager.shared.didFail(info, message: message) }
            return
        }
        // Dočasný soubor zmizí hned po návratu z této metody – přesun musí proběhnout tady.
        do {
            let fileManager = FileManager.default
            let destination = ModelPaths.staging(for: info.jobID).appending(path: info.path)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            Task { @MainActor in DownloadManager.shared.didFinish(info) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in DownloadManager.shared.didFail(info, message: message) }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let info = DownloadTaskInfo(downloadTask.taskDescription) else { return }
        // Hlásit nejvýš 4× za sekundu na soubor, ať se UI nezahltí.
        let now = Date()
        let identifier = downloadTask.taskIdentifier
        let shouldReport = lastReport.withLock { reports -> Bool in
            if let last = reports[identifier], now.timeIntervalSince(last) < 0.25 { return false }
            reports[identifier] = now
            return true
        }
        guard shouldReport else { return }
        Task { @MainActor in
            DownloadManager.shared.didWrite(info, written: totalBytesWritten, expectedTotal: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let identifier = task.taskIdentifier
        lastReport.withLock { _ = $0.removeValue(forKey: identifier) }
        guard let error, let info = DownloadTaskInfo(task.taskDescription) else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let message = error.localizedDescription
        Task { @MainActor in DownloadManager.shared.didFail(info, message: message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in DownloadManager.shared.finishBackgroundEvents() }
    }
}
