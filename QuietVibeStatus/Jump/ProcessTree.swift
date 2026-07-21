import AppKit
import Darwin

/// Walks up the process tree to find which application a process belongs to.
enum ProcessTree {
    /// Bundle id of the nearest ancestor that is a running application.
    ///
    /// Must be called **while the hook is still running**. The pid we capture belongs to the bridge
    /// shell, which exits the moment the hook returns — resolving this lazily at click time always
    /// failed, because by then `sysctl` can't find the process to walk up from.
    static func owningAppBundleID(of pid: pid_t) -> String? {
        var current = pid

        for _ in 0 ..< 16 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy != .prohibited,
               let bundleID = app.bundleIdentifier
            {
                return bundleID
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }

        return nil
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
