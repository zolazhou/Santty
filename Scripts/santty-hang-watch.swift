// santty-hang-watch.swift
//
// External hang watchdog for Santty.
//
// Polls the app's accessibility endpoint with a short messaging timeout. A
// responsive app answers an attribute query in well under a millisecond; a
// process whose main thread has stopped servicing its run loop leaves the AX
// request unanswered until the timeout fires. When that happens the watchdog
// takes a stack sample and records it, so the next 无响应 leaves evidence.
//
// Usage:
//   swiftc -O Scripts/santty-hang-watch.swift -o /tmp/santty-hang-watch
//   /tmp/santty-hang-watch                 # follows the newest running Santty
//   /tmp/santty-hang-watch <pid>           # pin one instance
//
// Output: ~/Library/Logs/SanttyHangs/hang-<timestamp>.txt (sample + probe log)

import AppKit
import ApplicationServices
import Foundation

let probeTimeout: Float = 1.0
let hangThreshold: TimeInterval = 1.0
let pollInterval: TimeInterval = 0.5
let reportCooldown: TimeInterval = 300
let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SanttyHangs", isDirectory: true)

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

/// Parent process id, from `proc_bsdinfo`. Used to tell an app apart from the
/// XCTest host that `flowdeck test` launches under the same bundle identifier.
func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.stride
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else { return nil }
    return pid_t(info.pbi_ppid)
}

func name(of pid: pid_t) -> String? {
    var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return URL(fileURLWithFileSystemRepresentation: path, isDirectory: false, relativeTo: nil)
        .lastPathComponent
}

/// A test host busy-looping inside a synchronous test looks exactly like a hang
/// from outside, so leave those alone.
func isTestHost(_ pid: pid_t) -> Bool {
    var current = pid
    for _ in 0 ..< 3 {
        guard let next = parentPID(of: current), next > 1 else { return false }
        if let parent = name(of: next), parent.hasPrefix("xctest") || parent.hasPrefix("XCTRunner") {
            return true
        }
        current = next
    }
    return false
}

func santtyPID() -> pid_t? {
    let identifiers = ["com.zolazhou.santty", "com.zolazhou.santty.dev"]
    let running = identifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    return running
        .filter { $0.activationPolicy != .prohibited && $0.processIdentifier > 0 }
        .filter { !isTestHost($0.processIdentifier) }
        .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }?
        .processIdentifier
}

func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

/// Cool-down between captures: one stuck process should not fill the disk.
/// A responsive app answers in well under a millisecond. A hung one lets the
/// request sit until `probeTimeout`, so the reported time is the *timeout*, not
/// the stall length — compare against a threshold far below it, and treat the
/// AX timeout errors as a hang on their own.
func probe(_ element: AXUIElement) -> TimeInterval {
    let start = CFAbsoluteTimeGetCurrent()
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
    guard error != .cannotComplete, error != .apiDisabled, error != .invalidUIElement else {
        return .infinity
    }
    return CFAbsoluteTimeGetCurrent() - start
}

func capture(pid: pid_t, latency: TimeInterval) {
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let path = outputDirectory.appendingPathComponent("hang-\(stamp).txt").path
    let description = latency.isInfinite ? "AX probe timed out; main thread not servicing its run loop" : "main thread stalled for \(String(format: "%.2f", latency))s"
    var report = "Santty \(description) (pid \(pid))\n\n"
    report += "### sample\n"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
    task.arguments = [String(pid), "2", "1"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        report += String(data: data, encoding: .utf8) ?? "<sample produced no output>"
    } catch {
        report += "<failed to run sample: \(error.localizedDescription)>\n"
    }
    try? report.write(toFile: path, atomically: true, encoding: .utf8)
    log("captured \(path)")
}

// MARK: - Entry point

let pinnedPID = CommandLine.arguments.dropFirst().first.flatMap { pid_t($0) }
var pid = pinnedPID ?? santtyPID()
if pid == nil, pinnedPID == nil {
    log("waiting for Santty to launch")
}
while pid == nil, pinnedPID == nil {
    Thread.sleep(forTimeInterval: 2)
    pid = santtyPID()
}
guard var watched = pid else {
    log("watched process is gone")
    exit(0)
}
log("watching Santty pid \(watched)\(pinnedPID == nil ? " (follows restarts)" : "")")

var element = AXUIElementCreateApplication(watched)
AXUIElementSetMessagingTimeout(element, probeTimeout)
var lastReport: Date = .distantPast

while true {
    if !isAlive(watched) {
        guard pinnedPID == nil else {
            log("watched process exited; stopping")
            exit(0)
        }
        if let replacement = santtyPID(), replacement != watched {
            watched = replacement
            element = AXUIElementCreateApplication(replacement)
            AXUIElementSetMessagingTimeout(element, probeTimeout)
            log("now watching Santty pid \(replacement)")
        }
        Thread.sleep(forTimeInterval: 2)
        continue
    }

    let latency = probe(element)
    if latency >= hangThreshold, Date().timeIntervalSince(lastReport) > reportCooldown {
        lastReport = Date()
        log(latency.isInfinite ? "AX probe timed out (main thread stalled)" : "main thread stalled for \(String(format: "%.2f", latency))s")
        capture(pid: watched, latency: latency)
    }
    Thread.sleep(forTimeInterval: pollInterval)
}
