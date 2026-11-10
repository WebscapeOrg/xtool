import Foundation
import XKit
import ArgumentParser
import XUtils

public enum XTool {
    public static func run(arguments: [String]? = nil) async throws {
        TemporaryDirectory.prepare()
        await XToolCommand.cancellableMain(arguments)
    }
}

private struct XToolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xtool",
        abstract: "Cross-platform Xcode replacement",
        version: "xtool \(XTool.version)",
        groupedSubcommands: [
            CommandGroup(
                name: "Configuration",
                subcommands: [
                    SetupCommand.self,
                    AuthCommand.self,
                    SDKCommand.self,
                ]
            ),
            CommandGroup(
                name: "Development",
                subcommands: [
                    NewCommand.self,
                    DevCommand.self,
                    DSCommand.self,
                ]
            ),
            CommandGroup(
                name: "Device",
                subcommands: [
                    DevicesCommand.self,
                    InstallCommand.self,
                    UninstallCommand.self,
                    LaunchCommand.self,
                ]
            )
        ]
    )
}

#if compiler(<6.2)
private typealias SendableMetatype = Any
#endif

/// How a build stops on SIGTERM. Until a command starts building, SIGTERM keeps its default action, so
/// commands such as `dev build-server` stop at once as before. From then on SIGTERM cancels the command,
/// which stops the swift build it started; killed outright, xtool left that build compiling in
/// xtool/.xtool-tmp without the build lock, where the next build deleted its folder. xtool then ends by
/// SIGTERM, so whoever sent it sees the same ending as before. A second SIGTERM, or a cancellation still
/// running after `graceSeconds`, ends it at once.
final class BuildTermination: @unchecked Sendable {
    static let shared = BuildTermination()
    static let graceSeconds = 10

    private let lock = NSLock()
    private var cancelRoot: (@Sendable () -> Void)?
    private var source: DispatchSourceSignal?
    private var received = false

    func setRoot(cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        cancelRoot = cancel
    }

    func buildStarting() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM)
        source.setEventHandler { [self] in terminate() }
        source.resume()
        self.source = source
    }

    var wasReceived: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Whether a SIGTERM has been received, waiting up to `seconds` for its handler to run.
    func received(within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !wasReceived && Date() < deadline {
            usleep(10_000)
        }
        return wasReceived
    }

    /// Ends xtool by SIGTERM if it received one, after what it printed has been written out.
    func endIfReceived() {
        if wasReceived { Self.end(flushing: true) }
    }

    private func terminate() {
        lock.lock()
        // On Darwin two signals that arrive together reach the handler once, with a count of two. Linux's
        // libdispatch always counts one, so there the grace period ends such a pair.
        let signals = source?.data ?? 1
        let again = received
        received = true
        let cancel = cancelRoot
        lock.unlock()
        guard !again, signals < 2 else { Self.end(flushing: false) }
        cancel?()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Self.graceSeconds)) {
            Self.end(flushing: false)
        }
    }

    /// Ends the process with SIGTERM's default action, as an xtool that did not handle it would have ended.
    private static func end(flushing: Bool) -> Never {
        if flushing { fflush(nil) }
        signal(SIGTERM, SIG_DFL)
        #if os(Linux)
        // libdispatch on Linux receives signals through a signalfd and blocks them in its threads.
        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, SIGTERM)
        pthread_sigmask(SIG_UNBLOCK, &unblock, nil)
        #endif
        raise(SIGTERM)
        _exit(128 + SIGTERM)
    }
}

extension ParsableCommand where Self: SendableMetatype {
    fileprivate static func cancellableMain(_ arguments: [String]? = nil) async {
        let (canStart, cont) = AsyncStream.makeStream(of: Never.self)
        let task = Task {
            for await _ in canStart {}
            guard !Task.isCancelled else { return }
            do {
                var command = try self.parseAsRoot(arguments)
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch where error is CancellationError || Task.isCancelled {
                print("Cancelled.")
                BuildTermination.shared.endIfReceived()
                self.exit()
            } catch SubprocessFailure.signaled(let code)
                where code == SIGTERM && BuildTermination.shared.received(within: 1) {
                // A SIGTERM sent to the whole process group can stop swift build before xtool's handler has run.
                print("Cancelled.")
                BuildTermination.shared.endIfReceived()
            } catch {
                if ProcessInfo.processInfo.environment["XTL_DEBUG_ERRORS"] != nil {
                    print("ERROR DETAILS:")
                    print(String(reflecting: error))
                }
                self.exit(withError: error)
            }
        }

        BuildTermination.shared.setRoot { task.cancel() }

        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT)
        source.setEventHandler { task.cancel() }
        source.resume()

        cont.finish()

        await task.value
        BuildTermination.shared.endIfReceived()
    }
}
