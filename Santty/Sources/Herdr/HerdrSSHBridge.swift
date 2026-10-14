import Foundation
import CryptoKit
import Darwin

struct HerdrSSHFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    var needsAttention: Bool {
        let text = message.lowercased()
        return ["permission denied", "host key verification", "host identification has changed", "no matching host key", "not found", "not ready", "compatible", "unsupported", "protocol"].contains { text.contains($0) }
    }
}

// Native Herdr remote-client-bridge / remote-api-bridge over OpenSSH stdio.
final class HerdrSSHBridge: @unchecked Sendable {
    struct Executable: Codable, Sendable {
        let os: String
        let executable: String
        var idleTimeout = false
        func validate() throws {
            let windows = os == "windows"
            let path = Array(executable.utf8.prefix(3))
            let drivePath = path.count == 3 && ((65...90).contains(path[0]) || (97...122).contains(path[0]))
                && path[1] == 58 && (path[2] == 92 || path[2] == 47)
            guard ["linux", "macos", "windows"].contains(os), !executable.isEmpty,
                  executable.utf8.count <= 4096,
                  !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  windows ? (executable.hasPrefix("\\\\") || drivePath) : executable.hasPrefix("/"),
                  !executable.hasSuffix("/mise/shims/herdr") else { throw CLIError("Invalid remote Herdr executable") }
        }
    }
    enum Lane { case client, api }
    private final class ExecutableCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Executable] = [:]
    }
    private static let executableCache = ExecutableCache()
    static let marker = "herdr-remote-output-ready:1"
    private let process: Process
    private let errors: Pipe
    private let configuration: URL?
    private let lock = NSLock()
    private var errorBytes = Data()
    private var stopped = false

    private init(process: Process, errors: Pipe, configuration: URL?) {
        self.process = process; self.errors = errors; self.configuration = configuration
    }

    deinit { stop(); if let configuration { try? FileManager.default.removeItem(at: configuration.deletingLastPathComponent()) } }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func powershell(_ script: String) -> String {
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand " + Data(script.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).base64EncodedString()
    }
    private static func psQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    static func command(executable: Executable, session: String, lane: Lane) throws -> String {
        try executable.validate()
        guard !session.isEmpty, session.utf8.count <= 64,
              session.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw CLIError("Invalid remote Herdr session") }
        let bridge = lane == .client ? "remote-client-bridge" + (executable.idleTimeout ? " --idle-timeout-v1" : "") : "remote-api-bridge"
        if executable.os == "windows" {
            return powershell("[Console]::Out.WriteLine('\(marker)'); [Console]::Out.Flush(); $p = Start-Process -FilePath \(psQuote(executable.executable)) -ArgumentList '--session \(session) \(bridge)' -NoNewWindow -PassThru -ErrorAction Stop; $null = $p.Handle; $p.WaitForExit(); exit $p.ExitCode")
        }
        return "/bin/sh -c " + quote("printf '%s\\n' \(quote(marker))\nexec \(quote(executable.executable)) --session \(quote(session)) \(bridge)")
    }

    static func connect(endpoint: HerdrEndpoint, lane: Lane, sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                        resolved: Executable? = nil) throws -> (fd: CInt, bridge: HerdrSSHBridge) {
        guard let machine = endpoint.machine else { throw CLIError("Missing SSH machine") }
        try machine.validate()
        let config = try configuration(target: machine.target)
        do {
            let key = endpoint.id + "\u{1F}" + machine.target + "\u{1F}" + machine.session
            executableCache.lock.lock(); let cached = executableCache.values[key]; executableCache.lock.unlock()
            let executable = try resolved ?? cached ?? discover(endpoint: endpoint, configuration: config, sshExecutable: sshExecutable)
            if resolved == nil { executableCache.lock.lock(); executableCache.values[key] = executable; executableCache.lock.unlock() }
            let process = Process(), errors = Pipe()
            var pair = [CInt](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw CLIError("Cannot create Herdr SSH stream") }
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); var noSignal: CInt = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<CInt>.size)) }
            let childStream = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
            process.executableURL = sshExecutable
            process.arguments = try arguments(target: machine.target, configuration: config) + [try command(executable: executable, session: machine.session, lane: lane)]
            process.standardInput = childStream; process.standardOutput = childStream; process.standardError = errors
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_ASKPASS_REQUIRE"] = "never"; environment.removeValue(forKey: "SSH_ASKPASS")
            process.environment = environment
            do { try process.run(); try childStream.close(); try errors.fileHandleForWriting.close() }
            catch { close(pair[0]); try? childStream.close(); if process.isRunning { process.terminate() }; throw error }
            let bridge = HerdrSSHBridge(process: process, errors: errors, configuration: config)
            DispatchQueue.global(qos: .utility).async { [bridge] in bridge.drainErrors() }
            do { try readMarker(fd: pair[0]); return (pair[0], bridge) }
            catch { close(pair[0]); bridge.stop(); throw HerdrSSHFailure(message: "Herdr SSH connection failed: \(bridge.errorSummary.isEmpty ? error.localizedDescription : bridge.errorSummary)") }
        } catch {
            invalidate(endpoint)
            if let config { try? FileManager.default.removeItem(at: config.deletingLastPathComponent()) }
            throw error
        }
    }

    static func invalidate(_ endpoint: HerdrEndpoint) {
        guard let machine = endpoint.machine else { return }
        let key = endpoint.id + "\u{1F}" + machine.target + "\u{1F}" + machine.session
        executableCache.lock.lock(); executableCache.values.removeValue(forKey: key); executableCache.lock.unlock()
    }

    static func readMarker(fd: CInt, timeout: TimeInterval = 20) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var line = Data(), total = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { throw CLIError("Cannot read SSH bridge preamble") }
            var byte: UInt8 = 0
            let count = Darwin.read(fd, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count == 1 else { throw CLIError("SSH exited before starting the Herdr bridge") }
            total += 1
            guard total <= 64 * 1024 else { throw CLIError("SSH bridge preamble exceeded its limit") }
            if byte == 10 {
                if String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == marker { return }
                line.removeAll(keepingCapacity: true)
            } else { line.append(byte) }
        }
        throw CLIError("SSH bridge startup timed out")
    }

    static func arguments(target: String, configuration: URL?) throws -> [String] {
        guard !target.isEmpty, !target.hasPrefix("-"), !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CLIError("Invalid SSH target") }
        var args = ["-C", "-T", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10", "-o", "ConnectionAttempts=1"]
        if let configuration {
            args += ["-F", configuration.path, "-S", try sharedControlPath(target: target), "-o", "ControlMaster=auto", "-o", "ControlPersist=600"]
        }
        args.append(target)
        return args
    }

    private static var configPath: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["HERDR_CONFIG_PATH"] { return URL(fileURLWithPath: path).standardizedFileURL }
        return URL(fileURLWithPath: env["XDG_CONFIG_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path)
            .appendingPathComponent("herdr/config.toml")
    }

    static func managesSSH(_ text: String) -> Bool {
        var remote = false
        for raw in text.split(separator: "\n") {
            let line = raw.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.hasPrefix("[") { remote = line == "[remote]" }
            if remote, line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "") == "manage_ssh_config=false" { return false }
        }
        return true
    }

    static func configuration(target: String) throws -> URL? {
        if let text = try? String(contentsOf: configPath, encoding: .utf8), !managesSSH(text) { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("santty-herdr-ssh-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("config")
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config").path
        let escaped = user.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let text = "Include \"\(escaped)\"\nInclude /etc/ssh/ssh_config\nHost *\n  ServerAliveInterval 15\n  ServerAliveCountMax 4\n"
        do { try Data(text.utf8).write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return path
    }

    private static func sharedControlPath(target: String) throws -> String {
        let directory = "/tmp/hssh-\(getuid())"
        if mkdir(directory, 0o700) != 0, errno != EEXIST { throw CLIError("Cannot create SSH control directory") }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw CLIError("Unsafe SSH control directory") }
        var bytes = Data(configPath.path.utf8); bytes.append(0); bytes.append(contentsOf: target.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return directory + "/" + hash.prefix(24) + "-%C"
    }

    private static func discover(endpoint: HerdrEndpoint, configuration: URL?, sshExecutable: URL) throws -> Executable {
        guard let machine = endpoint.machine else { throw CLIError("Missing Herdr machine") }
        let args = try arguments(target: machine.target, configuration: configuration)
        let script = "printf '%s\\n' \(quote(marker))\nuname -s\ncommand -v herdr\nfor p in \"$HOME/.local/bin/herdr\" /opt/homebrew/bin/herdr /usr/local/bin/herdr \"$HOME/.local/share/mise/installs/herdr\"/*/bin/herdr \"$HOME/.nix-profile/bin/herdr\" /etc/profiles/per-user/\"$USER\"/bin/herdr; do [ -x \"$p\" ] && printf '%s\\n' \"$p\"; done\n"
        let output = try HerdrProcess.run(sshExecutable, arguments: args + ["/bin/sh -c " + quote(script)], limit: 64 * 1024)
        if output.status == 255 { throw HerdrSSHFailure(message: String(decoding: output.stderr, as: UTF8.self)) }
        let lines = String(decoding: output.stdout, as: UTF8.self).components(separatedBy: .newlines)
        if let start = lines.firstIndex(of: marker), start + 1 < lines.count, ["Linux", "Darwin"].contains(lines[start + 1]) {
            let os = lines[start + 1] == "Darwin" ? "macos" : "linux"
            var seen = Set<String>()
            for path in lines.dropFirst(start + 2).prefix(64) where path.hasPrefix("/") && !path.hasSuffix("/mise/shims/herdr") && seen.insert(path).inserted {
                let executable = Executable(os: os, executable: path)
                if let compatible = try supportedExecutable(executable, arguments: args, sshExecutable: sshExecutable) { return compatible }
            }
        } else {
            let script = "[Console]::Out.WriteLine('\(marker)'); $paths = @((Get-Command herdr -CommandType Application -ErrorAction SilentlyContinue).Source); $homePath = if ($env:HERDR_HOME) { $env:HERDR_HOME } else { Join-Path $env:USERPROFILE '.herdr' }; $paths += Join-Path $homePath 'packages\\standalone\\current\\herdr.exe'; $paths += @(Get-CimInstance Win32_Process -Filter \"Name = 'herdr.exe'\" -ErrorAction SilentlyContinue | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwner).User -eq $env:USERNAME } | Select-Object -ExpandProperty ExecutablePath); $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique | ForEach-Object { [Console]::Out.WriteLine($_) }"
            let windows = try HerdrProcess.run(sshExecutable, arguments: args + [powershell(script)], limit: 64 * 1024)
            if windows.status == 255 { throw HerdrSSHFailure(message: String(decoding: windows.stderr, as: UTF8.self)) }
            let lines = String(decoding: windows.stdout, as: UTF8.self).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let start = lines.firstIndex(of: marker) {
                for path in lines.dropFirst(start + 1).prefix(64) where !path.isEmpty {
                    let executable = Executable(os: "windows", executable: path)
                    if let compatible = try supportedExecutable(executable, arguments: args, sshExecutable: sshExecutable) { return compatible }
                }
            }
        }
        throw HerdrSSHFailure(message: "Compatible Herdr was not found on \(machine.label). Run herdr --remote \(quote(machine.target)) --session \(quote(machine.session)) in a terminal to prepare it.")
    }

    private static func supportedExecutable(_ executable: Executable, arguments: [String], sshExecutable: URL) throws -> Executable? {
        try executable.validate()
        let command = executable.os == "windows" ? powershell("& \(psQuote(executable.executable)) status client --json") : quote(executable.executable) + " status client --json"
        let output = try HerdrProcess.run(sshExecutable, arguments: arguments + [command], limit: 64 * 1024)
        if output.status == 255 { throw HerdrSSHFailure(message: String(decoding: output.stderr, as: UTF8.self)) }
        guard output.status == 0 else { return nil }
        struct Status: Decodable { let endpoint_protocol_generation: Int?; let endpoint_capabilities: [String]?; let remote_host_bridge: Bool?; let remote_bridge_idle_timeout: Bool? }
        for line in output.stdout.split(separator: 10).reversed() {
            if let status = try? JSONDecoder().decode(Status.self, from: Data(line)) {
                guard status.endpoint_protocol_generation == 1,
                      executable.os != "windows" || status.remote_host_bridge == true,
                      Set(status.endpoint_capabilities ?? []).isSuperset(of: ["surface_interest", "health_check", "presentation_effects_fence"]) else { return nil }
                var compatible = executable; compatible.idleTimeout = status.remote_bridge_idle_timeout == true
                return compatible
            }
        }
        return nil
    }

    var errorSummary: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errorBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func drainErrors() {
        defer { try? errors.fileHandleForReading.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0, errno == EINTR { continue }
            if ready == 0 {
                lock.lock(); let finished = stopped; lock.unlock()
                if finished { return }
                continue
            }
            guard ready > 0 else { return }
            let count = Darwin.read(errors.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            lock.lock()
            errorBytes.append(contentsOf: bytes.prefix(count))
            if errorBytes.count > 4096 { errorBytes.removeFirst(errorBytes.count - 4096) }
            let finished = stopped
            lock.unlock()
            if finished { return }
        }
    }

    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
    }
}
