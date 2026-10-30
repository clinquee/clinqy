import Foundation
import Darwin

/// A cancellable process group with bounded output. A stopped shell must not leave its child commands running
/// or keep an inherited stdout pipe alive. The unreaped group leader prevents PID reuse during termination.
enum ProcessRunner {
    private final class Control: @unchecked Sendable {
        let lock = NSLock()
        var pid: pid_t?
        var cancelled = false
        var timedOut = false
        func stop(timeout: Bool = false) {
            lock.withLock {
                cancelled = true; timedOut = timedOut || timeout
                if let pid { kill(-pid, SIGTERM) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [self] in
                lock.withLock { if let pid { kill(-pid, SIGKILL) } }
            }
        }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20,
                    outputLimit: Int = 1_000_000, directory: URL? = nil) async -> (status: Int32, output: String) {
        let control = Control()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                var descriptors = [Int32](repeating: 0, count: 2)
                guard pipe(&descriptors) == 0 else { return (-1, "Couldn't create command output pipe") }
                let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
                var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
                posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
                defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
                posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
                posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
                posix_spawn_file_actions_addclose(&actions, descriptors[0])
                posix_spawn_file_actions_addclose(&actions, descriptors[1])
                posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                if #available(macOS 26, *) {
                    posix_spawn_file_actions_addchdir(&actions, (directory ?? FileManager.default.homeDirectoryForCurrentUser).path)
                } else { posix_spawn_file_actions_addchdir_np(&actions, (directory ?? FileManager.default.homeDirectoryForCurrentUser).path) }
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
                posix_spawnattr_setpgroup(&attributes, 0)
                var environment = ProcessInfo.processInfo.environment
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                let argv = ([path] + arguments).map { strdup($0) } + [nil]
                let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
                defer { argv.forEach { free($0) }; env.forEach { free($0) } }
                var pid: pid_t = 0
                let code: Int32 = control.lock.withLock {
                    guard !control.cancelled else { return ECANCELED }
                    let result = argv.withUnsafeBufferPointer { argv in
                        env.withUnsafeBufferPointer { env in posix_spawn(&pid, path, &actions, &attributes, argv.baseAddress!, env.baseAddress!) }
                    }
                    if result == 0 { control.pid = pid }
                    return result
                }
                Darwin.close(descriptors[1])
                guard code == 0 else { return (-1, code == ECANCELED ? "Command cancelled" : String(cString: strerror(code))) }
                let timer = DispatchWorkItem { control.stop(timeout: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
                defer { timer.cancel() }
                var output = Data(), truncated = false
                while let chunk = try? reader.read(upToCount: 65_536), !chunk.isEmpty {
                    let available = max(0, outputLimit - output.count)
                    output.append(chunk.prefix(available))
                    if chunk.count > available { truncated = true }
                }
                var status: Int32 = 0
                while true {
                    let ended = control.lock.withLock { () -> Bool in
                        // Kill remaining descendants before reaping the leader, even if they closed stdout.
                        if control.cancelled { kill(-pid, SIGKILL) }
                        let result = waitpid(pid, &status, WNOHANG)
                        if result == pid || result < 0 { control.pid = nil; return true }
                        return false
                    }
                    if ended { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                let timedOut = control.lock.withLock { control.timedOut }
                let cancelled = control.lock.withLock { control.cancelled }
                let exit: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                return (cancelled ? -1 : exit, String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    + (truncated ? "\n[Command output truncated]" : "") + (timedOut ? "\n(timed out)" : cancelled ? "\n(cancelled)" : ""))
            }.value
        } onCancel: { control.stop() }
    }
}
