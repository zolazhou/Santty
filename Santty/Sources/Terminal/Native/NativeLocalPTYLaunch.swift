import Darwin
import Foundation

/// Validated, immutable, explicit exec context. No shell command concatenation,
/// process-global environment mutation, remote routing or fallback executable.
struct NativeLocalPTYLaunch: Sendable {
    let paneID: UUID
    let executable: String
    let execName: String?
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String

    init(paneID: UUID, executable: String, execName: String? = nil, arguments: [String],
         environment: [String: String], workingDirectory: String) throws {
        let strings = [executable, workingDirectory] + arguments + Array(environment.keys) + Array(environment.values) + [execName].compactMap { $0 }
        guard executable.hasPrefix("/"), workingDirectory.hasPrefix("/"), execName != "",
              strings.allSatisfy({ !$0.utf8.contains(0) }),
              environment.keys.allSatisfy({ !$0.isEmpty && !$0.contains("=") }) else { throw NativeLocalPTYError.invalidArgument }
        self.paneID = paneID; self.executable = executable; self.execName = execName
        self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
    }

    /// LOCAL panes only. Preserve the user's actual environment/HOME/startup
    /// policy, unlike the lab allowlist. A remote shell must never use this.
    static func productionLocal(paneID: UUID, controlSocket: String, context: NativeLocalPTYUserContext,
                                workingDirectory: String? = nil, appVersion: String) throws -> Self {
        let shell = context.loginShell, home = context.homeDirectory
        let name = (shell as NSString).lastPathComponent
        guard shell.hasPrefix("/"), !name.isEmpty, name != "/", home.hasPrefix("/"),
              controlSocket.hasPrefix("/"), !controlSocket.utf8.contains(0) else { throw NativeLocalPTYError.invalidArgument }
        let cwd = workingDirectory ?? home
        var env = context.environment
        env["HOME"] = home; env["SHELL"] = shell; env["PWD"] = cwd
        if env["PATH"]?.isEmpty != false { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        if let locale = NativeLocalLocale.exports(currentLang: env["LANG"], locale: context.locale,
                                                  preferredLanguages: context.preferredLanguages) {
            env["LANG"] = locale.lang
            if let language = locale.language { env["LANGUAGE"] = language }
        }
        if env["LANG"]?.isEmpty != false { env["LANG"] = "en_US.UTF-8" }
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Santty"; env["TERM_PROGRAM_VERSION"] = appVersion
        env["SANTTY_PANE_ID"] = paneID.uuidString; env["SANTTY_CONTROL_SOCKET"] = controlSocket
        // These describe a parent terminal, not the new PTY. The actual cells
        // and pixels arrive in winsize before exec, with normal resize later.
        env.removeValue(forKey: "COLUMNS"); env.removeValue(forKey: "LINES")
        env.removeValue(forKey: "GHOSTTY_RESOURCES_DIR"); env.removeValue(forKey: "GHOSTTY_BIN_DIR")
        return try .init(paneID: paneID, executable: shell, execName: "-" + name, arguments: ["-i"],
                         environment: env, workingDirectory: cwd)
    }
}

struct NativeLocalPTYUserContext: Sendable {
    let loginShell: String
    let homeDirectory: String
    let environment: [String: String]
    let locale: Locale
    let preferredLanguages: [String]

    /// Read the current account record, with owned strings. No /bin/sh fallback,
    /// environment SHELL substitution, profile read, or process-wide setenv.
    static func current() throws -> Self {
        var capacity = 1024
        while capacity <= 1024 * 1024 {
            var buffer = [CChar](repeating: 0, count: capacity)
            var record = passwd(), found: UnsafeMutablePointer<passwd>?
            let account: (String, String)? = try buffer.withUnsafeMutableBufferPointer { bytes in
                let result = getpwuid_r(geteuid(), &record, bytes.baseAddress, bytes.count, &found)
                if result == ERANGE { return nil }
                guard result == 0, found != nil, let shell = record.pw_shell, let home = record.pw_dir,
                      let shell = String(validatingCString: shell), let home = String(validatingCString: home),
                      !shell.isEmpty, !home.isEmpty else { throw NativeLocalPTYError.invalidArgument }
                return (shell, home)
            }
            if let account {
                return .init(loginShell: account.0, homeDirectory: account.1,
                             environment: ProcessInfo.processInfo.environment, locale: .current,
                             preferredLanguages: Locale.preferredLanguages)
            }
            capacity *= 2
        }
        throw NativeLocalPTYError.invalidArgument
    }
}
