import Darwin

/// Signals for processes that this runtime may not have spawned, as the ledger needs.
enum ProcessGroup {
    /// Reports whether the pid exists. EPERM means it exists under another user.
    static func alive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    /// Sends SIGKILL to the group, else to the process.
    static func kill(pgid: pid_t, pid: pid_t) {
        if pgid > 0 && killpg(pgid, SIGKILL) == 0 { return }
        if pid > 0 { _ = Darwin.kill(pid, SIGKILL) }
    }
}
