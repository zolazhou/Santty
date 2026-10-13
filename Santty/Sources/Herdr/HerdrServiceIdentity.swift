import Foundation
import Darwin

struct HerdrServiceIdentity: Codable, Sendable, Equatable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func read(socket fd: CInt) throws -> Self {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
            throw CLIError("Cannot establish Herdr service identity")
        }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid() else { throw CLIError("Cannot verify Herdr process identity") }
        return .init(pid: pid, startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }
}
