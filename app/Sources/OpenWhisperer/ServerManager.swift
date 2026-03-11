import Foundation
import Combine

class ServerManager: ObservableObject {
    enum ServerStatus: String {
        case stopped = "Stopped"
        case starting = "Starting..."
        case running = "Running"
        case error = "Error"
    }

    @Published var status: ServerStatus = .stopped
    @Published var port: Int = 8000
    @Published var sttModel: String = ""
    @Published var ttsModel: String = ""

    private var process: Process?
    private var logHandle: FileHandle?
    private var healthCheckTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var pendingInitialCheck: DispatchWorkItem?
    private var startTime: Date?
    private var stopping = false

    private static let startupTimeout: TimeInterval = 300  // 5 min — first run downloads ~1.2GB of models
    private static let maxLogSize: UInt64 = 10 * 1024 * 1024  // 10MB

    var isRunning: Bool { status == .running }

    var statusLabel: String {
        switch status {
        case .running: return "Running"
        case .starting: return "Starting..."
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    func startAll() {
        let work = { [self] in
            Paths.ensureDirectories()
            startServer()
            startHealthChecks()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func stopAll(synchronous: Bool = false) {
        pendingRestart?.cancel()
        pendingRestart = nil

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        pendingInitialCheck?.cancel()
        pendingInitialCheck = nil

        stopping = true
        stopProcess(&process, pidFile: Paths.serverPidFile, synchronous: synchronous)
        status = .stopped
        sttModel = ""
        ttsModel = ""
    }

    func restartAll() {
        pendingRestart?.cancel()
        status = .stopped
        _ = ConfigManager.cleanTempFiles()

        let proc = process
        let procPid = proc?.processIdentifier
        process = nil

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        pendingInitialCheck?.cancel()
        pendingInitialCheck = nil

        let pidFile = Paths.serverPidFile

        // Terminate on main thread (Process is not Sendable), then restart
        let restart = DispatchWorkItem { [weak self] in
            if let proc, proc.isRunning {
                proc.terminate()
                // Wait in background for process to exit
                DispatchQueue.global(qos: .utility).async {
                    for _ in 0..<30 {
                        if !proc.isRunning { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if proc.isRunning, let pid = procPid {
                        kill(pid, SIGKILL)
                    }
                    try? FileManager.default.removeItem(at: pidFile)
                    DispatchQueue.main.async {
                        self?.startAll()
                    }
                }
            } else {
                try? FileManager.default.removeItem(at: pidFile)
                self?.startAll()
            }
        }
        pendingRestart = restart
        DispatchQueue.main.async(execute: restart)
    }

    // MARK: - Unified Server

    private func startServer() {
        // Clear stale process ref if it exited (L-5: prevents orphaned second Process)
        if let p = process, !p.isRunning { process = nil }
        guard process == nil else { return }

        status = .starting

        let proc = Process()
        proc.executableURL = Paths.python
        proc.arguments = [Paths.unifiedServer.path]
        proc.currentDirectoryURL = Paths.appSupport
        var env = makeEnv()
        env["SERVER_PORT"] = "\(port)"
        proc.environment = env

        let oldHandle = logHandle
        logHandle = nil
        try? oldHandle?.close()
        Self.rotateLogIfNeeded(at: Paths.serverLog)
        let logFile = FileHandle.forWritingOrCreate(at: Paths.serverLog)
        logFile.seekToEndOfFile()
        logHandle = logFile
        proc.standardOutput = logFile
        proc.standardError = logFile

        // Capture the log handle for THIS process so terminationHandler closes the right one
        let processLogHandle = logFile
        proc.terminationHandler = { [weak self] _ in
            try? processLogHandle.close()
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stopping {
                    self.stopping = false
                } else {
                    self.status = .error
                }
            }
        }

        process = proc
        startTime = Date()

        do {
            try proc.run()
            stopping = false
            writePID(proc.processIdentifier, to: Paths.serverPidFile)
        } catch {
            process = nil
            status = .error
            NSLog("Failed to start server: \(error)")
        }
    }

    // MARK: - Health Checks

    private static let startupCheckInterval: TimeInterval = 5   // faster polling during startup
    private static let runningCheckInterval: TimeInterval = 15  // relaxed polling once running

    private func startHealthChecks() {
        healthCheckTimer?.invalidate()
        let timer = Timer(timeInterval: Self.startupCheckInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer

        // Delay initial check — model loading typically takes 10-20s
        let initialCheck = DispatchWorkItem { [weak self] in
            self?.checkHealth()
        }
        pendingInitialCheck = initialCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: initialCheck)
    }

    private func checkHealth() {
        guard let url = URL(string: "http://localhost:\(port)/v1/models") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self, self.status == .starting || self.status == .running else { return }
                if ok {
                    let wasStarting = self.status == .starting
                    self.status = .running
                    if let data, self.sttModel.isEmpty || self.ttsModel.isEmpty {
                        self.parseModels(data)
                    }
                    // Switch to relaxed polling once server is confirmed running
                    if wasStarting {
                        self.healthCheckTimer?.invalidate()
                        let timer = Timer(timeInterval: Self.runningCheckInterval, repeats: true) { [weak self] _ in
                            self?.checkHealth()
                        }
                        RunLoop.main.add(timer, forMode: .common)
                        self.healthCheckTimer = timer
                    }
                } else if self.status == .starting,
                          let start = self.startTime,
                          Date().timeIntervalSince(start) > Self.startupTimeout {
                    self.status = .error
                }
            }
        }.resume()
    }

    private func parseModels(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return }
        for model in models {
            guard let id = model["id"] as? String else { continue }
            let short = id.components(separatedBy: "/").last ?? id
            let type = model["type"] as? String ?? ""
            if type == "stt" {
                sttModel = short.replacingOccurrences(of: "whisper-", with: "")
            } else if type == "tts" {
                ttsModel = short
            }
        }
    }

    // MARK: - Process Management

    /// Waits for process to exit after terminate(). Must NOT be called on main thread (T-1).
    private static func waitForTermination(_ process: Process?, pidFile: URL) {
        guard let proc = process, proc.isRunning else {
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        proc.terminate()
        for _ in 0..<30 {
            if !proc.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.interrupt()
            for _ in 0..<10 {
                if !proc.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func stopProcess(_ process: inout Process?, pidFile: URL, synchronous: Bool = false) {
        guard let proc = process, proc.isRunning else {
            process = nil
            try? FileManager.default.removeItem(at: pidFile)
            return
        }
        process = nil
        proc.terminate()
        if synchronous {
            // Run termination inline on current thread (H-5: avoid semaphore blocking main thread)
            Self.waitForTermination(proc, pidFile: pidFile)
        } else {
            DispatchQueue.global(qos: .utility).async {
                Self.waitForTermination(proc, pidFile: pidFile)
            }
        }
    }

    private func writePID(_ pid: Int32, to url: URL) {
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func rotateLogIfNeeded(at url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let backup = url.appendingPathExtension("old")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
    }

    private func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let venvBin = Paths.venv.appendingPathComponent("bin").path
        env["PATH"] = "\(venvBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["VIRTUAL_ENV"] = Paths.venv.path
        return env
    }
}

// MARK: - FileHandle Helper

extension FileHandle {
    static func forWritingOrCreate(at url: URL) -> FileHandle {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return (try? FileHandle(forWritingTo: url)) ?? FileHandle.nullDevice
    }
}
