import Foundation
import SwiftUI

class SetupManager: ObservableObject {
    enum SetupState: Equatable {
        case notStarted
        case inProgress(String)
        case complete
        case failed(String)
    }

    @Published var state: SetupState = .notStarted
    @Published var progress: Double = 0
    private var isSetupRunning = false

    var isSetupComplete: Bool {
        FileManager.default.fileExists(atPath: Paths.setupComplete.path)
    }

    /// Run full first-launch setup
    func runFirstLaunchSetup(completion: @escaping (Bool) -> Void) {
        guard !isSetupComplete else {
            completion(true)
            return
        }
        guard !isSetupRunning else { return }
        isSetupRunning = true

        Paths.ensureDirectories()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            updateState(.inProgress("Creating Python environment..."), progress: 0.1)

            // Step 1: Create venv with bundled uv — try Python 3.13, fall back to 3.12/3.11
            var venvCreated = false
            for pyVersion in ["3.13", "3.12", "3.11"] {
                if runCommand(
                    Paths.uvBinary.path,
                    args: ["venv", Paths.venv.path, "--python", pyVersion, "--clear"],
                    step: "Creating Python \(pyVersion) environment...",
                    timeout: 120
                ) {
                    venvCreated = true
                    NSLog("Created venv with Python \(pyVersion)")
                    break
                }
                NSLog("Python \(pyVersion) not available, trying next...")
            }
            guard venvCreated else {
                updateState(.failed("Failed to create Python venv — no Python 3.11+ found"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 2: Install mlx-audio
            updateState(.inProgress("Installing MLX Audio (TTS)..."), progress: 0.2)
            guard uvPipInstall("mlx-audio", timeout: 600) else {
                updateState(.failed("Failed to install mlx-audio"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 3: Install mlx-whisper
            updateState(.inProgress("Installing MLX Whisper (STT)..."), progress: 0.4)
            guard uvPipInstall("mlx-whisper", timeout: 600) else {
                updateState(.failed("Failed to install mlx-whisper"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 4: Install spaCy + model (required by Kokoro TTS)
            updateState(.inProgress("Installing language model..."), progress: 0.6)
            guard uvPipInstall("spacy", timeout: 300) else {
                updateState(.failed("Failed to install spaCy"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }
            // Install matching en_core_web_sm via spacy download (ensures version compatibility)
            guard runCommand(
                Paths.python.path,
                args: ["-m", "spacy", "download", "en_core_web_sm"],
                step: "Downloading spaCy language model...",
                timeout: 120
            ) else {
                updateState(.failed("Failed to install spaCy model"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 5: Install setuptools (required by Kokoro TTS for pkg_resources)
            updateState(.inProgress("Installing dependencies..."), progress: 0.7)
            guard uvPipInstall("setuptools<81", timeout: 120) else {
                updateState(.failed("Failed to install setuptools — TTS requires it"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            // Step 6: Smoke test — verify critical imports work
            updateState(.inProgress("Verifying installation..."), progress: 0.85)
            guard runCommand(
                Paths.python.path,
                args: ["-c", "import mlx_whisper; import mlx_audio; import spacy; print('OK')"],
                step: "Import smoke test...",
                timeout: 30
            ) else {
                updateState(.failed("Installation verification failed — try Setup > Reset"), progress: 0)
                DispatchQueue.main.async {
                    self.isSetupRunning = false
                    completion(false)
                }
                return
            }

            updateState(.inProgress("Finishing up..."), progress: 0.9)

            // Mark setup complete (only after all steps + smoke test pass)
            try? "done".write(to: Paths.setupComplete, atomically: true, encoding: .utf8)

            updateState(.complete, progress: 1.0)
            DispatchQueue.main.async {
                self.isSetupRunning = false
                completion(true)
            }
        }
    }

    /// Re-run setup (e.g., after update)
    func resetAndRerun(completion: @escaping (Bool) -> Void) {
        guard !isSetupRunning else { return }
        try? FileManager.default.removeItem(at: Paths.setupComplete)
        runFirstLaunchSetup(completion: completion)
    }

    // MARK: - Private

    private func uvPipInstall(_ package: String, timeout: TimeInterval = 300) -> Bool {
        runCommand(
            Paths.uvBinary.path,
            args: ["pip", "install", "--python", Paths.python.path, package],
            step: "Installing \(package)...",
            timeout: timeout
        )
    }

    private func runCommand(_ executable: String, args: [String], step: String, timeout: TimeInterval = 300) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let logFile = FileHandle.forWritingOrCreate(at: Paths.setupLog)
        logFile.seekToEndOfFile()
        if let logData = "=== \(step) ===\n\(executable) \(args.joined(separator: " "))\n".data(using: .utf8) {
            logFile.write(logData)
        }
        process.standardOutput = logFile
        process.standardError = logFile

        do {
            try process.run()

            // Wait with timeout to prevent indefinite hangs
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            if process.isRunning {
                NSLog("Setup step timed out after \(Int(timeout))s: \(step)")
                process.terminate()
                Thread.sleep(forTimeInterval: 1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                try? logFile.close()
                return false
            }

            try? logFile.close()
            let success = process.terminationStatus == 0
            if !success {
                NSLog("Setup step failed: \(step) (exit \(process.terminationStatus))")
            }
            return success
        } catch {
            try? logFile.close()
            NSLog("Setup step error: \(step) — \(error)")
            return false
        }
    }

    private func updateState(_ state: SetupState, progress: Double) {
        DispatchQueue.main.async {
            self.state = state
            self.progress = progress
        }
    }
}
