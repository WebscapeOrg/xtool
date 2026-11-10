import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Lets one xtool build run at a time in a package folder.
///
/// `Packer` deletes and recreates `xtool/.xtool-tmp` at the start of every build, and `pack()` replaces
/// `xtool/<App>.app`. A second build started in the same folder deleted the folder the first one was
/// compiling in, and its `swift-frontend` aborted with a working directory that no longer existed.
/// The lock is an advisory `flock` on `xtool/.xtool-build.lock`. It is held until the process exits,
/// so it also covers signing, packaging and installing the bundle the build wrote. A build that finds
/// the lock taken says so on standard error and waits; Ctrl-C still stops it while it waits.
///
/// The lock is not inherited by the programs xtool starts, so a build service they leave running
/// cannot hold it after xtool exits. The cost is that a `swift build` that outlives a killed xtool
/// runs without it. `dev run` holds the lock until the app is installed, including while it waits
/// for a device, so a build behind it waits that long too and names the pid it waits for.
public enum BuildLock {
    public static let fileName = ".xtool-build.lock"

    private static let guardLock = NSLock()
    nonisolated(unsafe) private static var heldByThisProcess = false

    /// Takes the lock for the package in the current directory, once per process. When the lock cannot
    /// be taken at all, as on a file system without `flock`, the build goes on without it and says so.
    public static func acquireForThisProcess(xtoolDirectory: URL = URL(fileURLWithPath: "xtool")) async throws {
        guard !isHeld() else { return }
        // Invariant: the descriptor is never closed. Closing it would let the next build in before this
        // process has finished with the bundle; the system releases the lock when the process exits.
        let descriptor = try await lock(in: xtoolDirectory, warn: tell) { holder in
            let who = holder.map { " (pid \($0))" } ?? ""
            tell("Waiting for another xtool build in this folder to finish\(who)...")
        }
        if descriptor != nil { markHeld() }
    }

    /// Takes the lock in `xtoolDirectory` and returns its descriptor, or nil when it could not be taken,
    /// after telling `warn` why. When another process holds it, `waiting` is told that process's pid, if it
    /// wrote one, and the call checks again every `pollNanoseconds` until it is free or the task is cancelled.
    static func lock(
        in xtoolDirectory: URL,
        pollNanoseconds: UInt64 = 250_000_000,
        warn: (String) -> Void,
        waiting: (Int32?) -> Void
    ) async throws -> Int32? {
        let path = xtoolDirectory.appendingPathComponent(fileName).path
        let withoutIt = "so this build runs without the lock that stops a second build in this folder from deleting its files"
        var told = false
        while true {
            // Each time round, since the folder may have gone with the lock file (git clean -fdx) while this build waited.
            do {
                try FileManager.default.createDirectory(at: xtoolDirectory, withIntermediateDirectories: true)
            } catch {
                warn("warning: Could not create \(xtoolDirectory.path) (\(error)), \(withoutIt).")
                return nil
            }
            // Invariant: close-on-exec, so swift build and the other tools xtool starts do not inherit the lock.
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                let reason = errno
                warn("warning: Could not open \(path) (\(describe(reason))), \(withoutIt).")
                return nil
            }
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let reason = errno
                if reason == EINTR { continue }
                guard reason == EWOULDBLOCK else {
                    close(descriptor)
                    warn("warning: Could not lock \(path) (\(describe(reason))), \(withoutIt).")
                    return nil
                }
                if !told {
                    waiting(holder(of: path))
                    told = true
                }
                do {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                } catch {
                    close(descriptor)
                    throw error
                }
            }
            // Invariant: the locked file is the one at the path. If the file was deleted or replaced while this
            // build waited, the lock it now has is on a file no other build will open, so it starts again.
            guard isStillAtPath(descriptor, path) else {
                close(descriptor)
                continue
            }
            let pid = Array("\(getpid())\n".utf8)
            if ftruncate(descriptor, 0) == 0 {
                _ = pid.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
            }
            return descriptor
        }
    }

    static func isStillAtPath(_ descriptor: Int32, _ path: String) -> Bool {
        var opened = stat()
        var atPath = stat()
        guard fstat(descriptor, &opened) == 0, stat(path, &atPath) == 0 else { return false }
        return opened.st_dev == atPath.st_dev && opened.st_ino == atPath.st_ino
    }

    /// The pid the lock file names, when that process is still running. Until a new holder writes its own,
    /// the file still names the previous one, which may have exited.
    static func holder(of path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0
        else { return nil }
        return kill(pid, 0) == 0 || errno == EPERM ? pid : nil
    }

    private static func describe(_ reason: Int32) -> String {
        String(cString: strerror(reason))
    }

    static func isHeld() -> Bool {
        guardLock.lock()
        defer { guardLock.unlock() }
        return heldByThisProcess
    }

    private static func markHeld() {
        guardLock.lock()
        defer { guardLock.unlock() }
        heldByThisProcess = true
    }

    /// Standard error is unbuffered, so the line shows at once in a log or a pipe, where standard output
    /// would hold it until xtool exits.
    private static func tell(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
