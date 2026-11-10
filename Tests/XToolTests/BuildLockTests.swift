import Foundation
import Testing
@testable import PackLib
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private final class Folder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildLockTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("xtool", isDirectory: true)
    }

    var lockPath: String { url.appendingPathComponent(BuildLock.fileName).path }

    /// Whether a separate open of the lock file could take it now, as another xtool process would.
    func takenByAnother() throws -> Bool {
        let other = open(lockPath, O_RDWR)
        try #require(other >= 0, "the lock file is missing")
        defer { close(other) }
        if flock(other, LOCK_EX | LOCK_NB) == 0 {
            flock(other, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    deinit {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var holders: [Int32?] = []

    func record(_ holder: Int32?) {
        lock.lock()
        defer { lock.unlock() }
        holders.append(holder)
    }

    var recorded: [Int32?] {
        lock.lock()
        defer { lock.unlock() }
        return holders
    }
}

private final class Warnings: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func record(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

/// A pid no running process has: Linux caps pids at 2^22, and macOS well below that.
private let exitedPid: Int32 = 2_147_483_000

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct BuildLockTests {
    @Test func theLockIsHeldWithThisProcessPidUntilItsDescriptorCloses() async throws {
        let folder = try Folder()
        let warnings = Warnings()
        var told = false
        let descriptor = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in told = true })
        #expect(!told)
        #expect(try folder.takenByAnother())
        #expect(BuildLock.holder(of: folder.lockPath) == getpid())
        close(descriptor)
        #expect(!(try folder.takenByAnother()))
        #expect(warnings.recorded.isEmpty)
    }

    @Test func aSecondBuildSaysWhoHoldsItAndWaitsUntilItIsFree() async throws {
        let folder = try Folder()
        let warnings = Warnings()
        let first = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in })
        let waits = Waits()
        let url = folder.url
        let second = Task.detached {
            try await BuildLock.lock(in: url, pollNanoseconds: 10_000_000, warn: warnings.record) { waits.record($0) }
        }
        try await waitUntil { !waits.recorded.isEmpty }
        #expect(waits.recorded == [getpid()])
        try await Task.sleep(nanoseconds: 200_000_000)
        close(first)
        let descriptor = try #require(try await second.value)
        #expect(try folder.takenByAnother())
        close(descriptor)
        #expect(waits.recorded.count == 1)
        #expect(warnings.recorded.isEmpty)
    }

    @Test func ctrlCStopsABuildThatIsWaitingWithoutTakingTheLock() async throws {
        let folder = try Folder()
        let warnings = Warnings()
        let first = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in })
        defer { close(first) }
        let waits = Waits()
        let url = folder.url
        let second = Task.detached {
            try await BuildLock.lock(in: url, pollNanoseconds: 10_000_000, warn: warnings.record) { waits.record($0) }
        }
        try await waitUntil { !waits.recorded.isEmpty }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        flock(first, LOCK_UN)
        #expect(!(try folder.takenByAnother()))
        #expect(warnings.recorded.isEmpty)
    }

    @Test func aBuildWaitingOnALockFileThatWasDeletedWaitsForTheBuildHoldingTheNewOne() async throws {
        let folder = try Folder()
        let warnings = Warnings()
        let first = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in })
        let waits = Waits()
        let url = folder.url
        let waiter = Task.detached {
            try await BuildLock.lock(in: url, pollNanoseconds: 10_000_000, warn: warnings.record) { waits.record($0) }
        }
        try await waitUntil { !waits.recorded.isEmpty }
        try FileManager.default.removeItem(atPath: folder.lockPath)
        let replacement = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in })
        close(first)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try folder.takenByAnother())
        close(replacement)
        let descriptor = try #require(try await waiter.value)
        #expect(BuildLock.isStillAtPath(descriptor, folder.lockPath))
        close(descriptor)
        #expect(warnings.recorded.isEmpty)
    }

    @Test func aBuildWaitingWhenTheWholeXtoolFolderIsRemovedTakesALockInANewOne() async throws {
        let folder = try Folder()
        let warnings = Warnings()
        let first = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in })
        let waits = Waits()
        let url = folder.url
        let waiter = Task.detached {
            try await BuildLock.lock(in: url, pollNanoseconds: 10_000_000, warn: warnings.record) { waits.record($0) }
        }
        try await waitUntil { !waits.recorded.isEmpty }
        try FileManager.default.removeItem(at: folder.url)
        close(first)
        let descriptor = try #require(try await waiter.value)
        #expect(BuildLock.isStillAtPath(descriptor, folder.lockPath))
        #expect(try folder.takenByAnother())
        close(descriptor)
        #expect(warnings.recorded.isEmpty)
    }

    @Test func theWaitingMessageNamesNoPidForAHolderThatHasExited() throws {
        let folder = try Folder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try Data("\(exitedPid)\n".utf8).write(to: URL(fileURLWithPath: folder.lockPath))
        #expect(BuildLock.holder(of: folder.lockPath) == nil)
        try Data("\(getpid())\n".utf8).write(to: URL(fileURLWithPath: folder.lockPath))
        #expect(BuildLock.holder(of: folder.lockPath) == getpid())
    }

    @Test func aFolderThatCannotHoldTheLockFileLetsTheBuildGoOnAndSaysSo() async throws {
        let folder = try Folder()
        try FileManager.default.createDirectory(at: folder.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: folder.url.path, contents: Data()))
        let warnings = Warnings()
        let descriptor = try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in }
        #expect(descriptor == nil)
        #expect(warnings.recorded.count == 1)
        #expect(warnings.recorded.first?.contains("runs without the lock") == true)
    }

    @Test func programsXtoolStartsDoNotInheritTheLock() async throws {
        let folder = try Folder()
        let warnings = Warnings()
        let descriptor = try #require(try await BuildLock.lock(in: folder.url, warn: warnings.record) { _ in })
        defer { close(descriptor) }
        #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(warnings.recorded.isEmpty)
    }

    /// The only test that takes the lock for the whole process, which no test can give back.
    @Test func theBuildCommandHoldsTheLockForTheRestOfTheProcess() async throws {
        let folder = try Folder()
        try await BuildLock.acquireForThisProcess(xtoolDirectory: folder.url)
        #expect(BuildLock.isHeld())
        #expect(try folder.takenByAnother())
        #expect(BuildLock.holder(of: folder.lockPath) == getpid())
        // A second call returns at once rather than waiting on this process's own lock; the time limit fails it otherwise.
        try await BuildLock.acquireForThisProcess(xtoolDirectory: folder.url)
        #expect(try folder.takenByAnother())
    }
}
