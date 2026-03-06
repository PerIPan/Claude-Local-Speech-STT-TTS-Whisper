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

    private var sttProcess: Process?
    private var ttsProcess: Process?
    private var healthCheckTimer: Timer?

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
        Paths.ensureDirectories()
        startSTT()
        startTTS()
        startHealthChecks()
    }

    func stopAll() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        stopProcess(&sttProcess, pidFile: Paths.sttPidFile)
        stopProcess(&ttsProcess, pidFile: Paths.ttsPidFile)
        DispatchQueue.main.async {
            self.sttStatus = .stopped
            self.ttsStatus = .stopped
        }
    }

    func restartAll() {
        stopAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.startAll()
        }
    }

    // MARK: - STT Server

    private func startSTT() {
        guard sttProcess == nil || !sttProcess!.isRunning else { return }

        DispatchQueue.main.async { self.sttStatus = .starting }

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = [Paths.whisperServer.path]
        process.currentDirectoryURL = Paths.appSupport
        process.environment = makeEnv()

        let logFile = FileHandle.forWritingOrCreate(at: Paths.sttLog)
        process.standardOutput = logFile
        process.standardError = logFile

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if self?.sttProcess === proc {
                    self?.sttStatus = .error
                }
            }
        }

        do {
            try process.run()
            sttProcess = process
            writePID(process.processIdentifier, to: Paths.sttPidFile)
        } catch {
            DispatchQueue.main.async { self.sttStatus = .error }
            NSLog("Failed to start STT: \(error)")
        }
    }

    // MARK: - TTS Server

    private func startTTS() {
        guard ttsProcess == nil || !ttsProcess!.isRunning else { return }

        DispatchQueue.main.async { self.ttsStatus = .starting }

        let process = Process()
        process.executableURL = Paths.python
        process.arguments = ["-m", "mlx_audio.server", "--host", "127.0.0.1", "--port", "8100"]
        process.currentDirectoryURL = Paths.appSupport
        process.environment = makeEnv()

        let logFile = FileHandle.forWritingOrCreate(at: Paths.ttsLog)
        process.standardOutput = logFile
        process.standardError = logFile

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                if self?.ttsProcess === proc {
                    self?.ttsStatus = .error
                }
            }
        }

        do {
            try process.run()
            ttsProcess = process
            writePID(process.processIdentifier, to: Paths.ttsPidFile)
        } catch {
            DispatchQueue.main.async { self.ttsStatus = .error }
            NSLog("Failed to start TTS: \(error)")
        }
    }

    // MARK: - Health Checks

    private func startHealthChecks() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        // First check after 3s to give servers time to boot
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        checkEndpoint("http://localhost:8000/models") { [weak self] ok in
            DispatchQueue.main.async {
                if self?.sttProcess?.isRunning == true {
                    self?.sttStatus = ok ? .running : .starting
                }
            }
        }
        checkEndpoint("http://localhost:8100/v1/models") { [weak self] ok in
            DispatchQueue.main.async {
                if self?.ttsProcess?.isRunning == true {
                    self?.ttsStatus = ok ? .running : .starting
                }
            }
        }
    }

    private func checkEndpoint(_ urlString: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            completion(ok)
        }.resume()
    }

    // MARK: - Process Management

    private func stopProcess(_ process: inout Process?, pidFile: URL) {
        let proc = process
        process = nil  // Clear first so termination handler's === check fails
        if let proc = proc, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func writePID(_ pid: Int32, to url: URL) {
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let venvBin = Paths.venv.appendingPathComponent("bin").path
        env["PATH"] = "\(venvBin):/usr/local/bin:/usr/bin:/bin"
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
