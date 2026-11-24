import Darwin
import Foundation

/// Local process inspection only; production terminals use the stronger owned
/// PTY lease from NativeLocalPTYSession. Never use this for a remote PID.
enum ProcessWorkingDirectoryResolver {
    static func workingDirectory(for processID: Int32) -> String? {
        guard processID > 0 else { return nil }
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(processID,PROC_PIDVNODEPATHINFO,0,&info,Int32(MemoryLayout.size(ofValue:info))) == MemoryLayout.size(ofValue:info) else { return nil }
        return withUnsafeBytes(of:&info.pvi_cdir.vip_path) { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to:CChar.self) else { return nil }
            return String(validatingCString:base)
        }
    }
}
