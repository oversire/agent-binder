import Darwin

/// The start time of a live pid. A different token for the same pid means the pid was reused.
enum StartToken {
    static func of(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }
}
