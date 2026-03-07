import Foundation
import Combine

class ServerManager: ObservableObject {
    enum ServerStatus: String {
        case stopped = "Stopped"
        case starting = "Starting..."
        case running = "Running"
        case error = "Error"
    }

    @Published var sttStatus: ServerStatus = .stopped
    @Published var ttsStatus: ServerStatus = .stopped
    @Published var sttPort: Int = 8000
    @Published var ttsPort: Int = 8100

    private var sttProcess: Process?
    private var ttsProcess: Process?
    private var healthCheckTimer: Timer?
    private var pendingRestart: DispatchWorkItem?
    private var pendingInitialCheck: DispatchWorkItem?
    private var stoppingSTT = false
    private var stoppingTTS = false

    var isRunning: Bool {
        sttStatus == .running && ttsStatus == .running
    }

    var statusLabel: String {
        if sttStatus == .running && ttsStatus == .running { return "Running" }
        if sttStatus == .starting || ttsStatus == .starting { return "Starting..." }
        if sttStatus == .error || ttsStatus == .error { return "Error" }
        return "Stopped"
    }

    func startAll() {
        // Must run on main thread for timer scheduling (BUG-08)
        let work = { [self] in
            Paths.ensureDirectories()
            startSTT()
            startTTS()
            startHealthChecks()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func stopAll() {
        // Cancel any pending restart (BUG-12)
        pendingRestart?.cancel()
        pendingRestart = nil

        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        pendingInitialCheck?.cancel()
        pendingInitialCheck = nil

        // Non-blocking stop (BUG-02)
        stoppingSTT = true
        stoppingTTS = true
        stopProcess(&sttProcess, pidFile: Paths.sttPidFile)
        stopProcess(&ttsProcess, pidFile: Paths.ttsPidFile)

        sttStatus = .stopped
        ttsStatus = .stopped
    }

    func restartAll() {
        // Cancel any previous pending restart (BUG-12)
        pendingRestart?.cancel()

        stopAll()

        let restart = DispatchWorkItem { [weak self] in
            self?.startAll()
        }
        pendingRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: restart)
    }

    // MARK: - STT Server

    private func startSTT() {
        guard sttProcess == nil || sttProcess?.isRunning != true else { return }

        sttStatus = .starting

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = [Paths.whisperServer.path]
        process.currentDirectoryURL = Paths.appSupport
        var env = makeEnv()
        env["STT_PORT"] = "\(sttPort)"
        process.environment = env

        let logFile = FileHandle.forWritingOrCreate(at: Paths.sttLog)
        process.standardOutput = logFile
        process.standardError = logFile

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stoppingSTT {
                    self.stoppingSTT = false
                } else {
                    self.sttStatus = .error
                }
            }
        }

        stoppingSTT = false
        sttProcess = process

        do {
            try process.run()
            writePID(process.processIdentifier, to: Paths.sttPidFile)
        } catch {
            sttProcess = nil
            sttStatus = .error
            NSLog("Failed to start STT: \(error)")
        }
    }

    // MARK: - TTS Server

    private func startTTS() {
        guard ttsProcess == nil || ttsProcess?.isRunning != true else { return }

        ttsStatus = .starting

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = ["-m", "mlx_audio.server", "--host", "127.0.0.1", "--port", "\(ttsPort)"]
        process.currentDirectoryURL = Paths.appSupport
        process.environment = makeEnv()

        let logFile = FileHandle.forWritingOrCreate(at: Paths.ttsLog)
        process.standardOutput = logFile
        process.standardError = logFile

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.stoppingTTS {
                    self.stoppingTTS = false
                } else {
                    self.ttsStatus = .error
                }
            }
        }

        stoppingTTS = false
        ttsProcess = process

        do {
            try process.run()
            writePID(process.processIdentifier, to: Paths.ttsPidFile)
        } catch {
            ttsProcess = nil
            ttsStatus = .error
            NSLog("Failed to start TTS: \(error)")
        }
    }

    // MARK: - Health Checks

    private func startHealthChecks() {
        // Timer must be on main thread RunLoop (BUG-08)
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        // Cancellable first check after 3s to give servers time to boot
        let initialCheck = DispatchWorkItem { [weak self] in
            self?.checkHealth()
        }
        pendingInitialCheck = initialCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: initialCheck)
    }

    private func checkHealth() {
        checkEndpoint("http://localhost:\(sttPort)/models") { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.sttStatus == .starting || self.sttStatus == .running else { return }
                self.sttStatus = ok ? .running : .starting
            }
        }
        checkEndpoint("http://localhost:\(ttsPort)/v1/models") { [weak self] ok in
            DispatchQueue.main.async {
                guard let self, self.ttsStatus == .starting || self.ttsStatus == .running else { return }
                self.ttsStatus = ok ? .running : .starting
            }
        }
    }

    private func checkEndpoint(_ urlString: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok)
        }.resume()
    }

    // MARK: - Process Management

    private func stopProcess(_ process: inout Process?, pidFile: URL) {
        if let proc = process, proc.isRunning {
            proc.terminate()
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
            }
        }
        process = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func writePID(_ pid: Int32, to url: URL) {
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
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
