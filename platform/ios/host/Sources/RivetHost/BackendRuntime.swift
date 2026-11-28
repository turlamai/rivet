import Foundation
import RivetEmbedding
import RivetRuntime

/// Locates the canonical Rivet runtime layout inside the app.
///
/// `raco rivet build` stages `runtime/*.boot` (the portable-bytecode boot
/// files of the cross-built Racket CS) and `res/core.zo` (the product
/// backend, compiled to the same portable bytecode) into this directory,
/// where the Xcode project references them as folders so both land in the
/// app bundle verbatim. `Bundle.main.resourceURL` is that bundle root, the
/// same root `EmbeddedRacketConfiguration.resolvedDefault` scans on macOS.
///
/// The updater stack is intentionally NOT linked here: App Store policy
/// forbids a post-review code-download path, so a standalone iOS host runs
/// only the backend it shipped with.
enum BackendRuntime {
    static func configuration(
        moduleName: String,
        entryName: String
    ) throws -> EmbeddedRacketConfiguration {
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL)
        }

        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

        var searchedRoots: [URL] = []
        for candidate in roots {
            let root = candidate.standardizedFileURL
            searchedRoots.append(root)
            let runtime = root.appendingPathComponent("runtime", isDirectory: true)
            let required = [
                runtime.appendingPathComponent("petite.boot"),
                runtime.appendingPathComponent("scheme.boot"),
                runtime.appendingPathComponent("racket.boot"),
                root.appendingPathComponent("res/core.zo")
            ]
            let fileManager = FileManager.default
            guard required.allSatisfy({ url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue
            }) else { continue }

            return EmbeddedRacketConfiguration(
                executable: executable,
                petiteBoot: required[0],
                schemeBoot: required[1],
                racketBoot: required[2],
                core: required[3],
                workingDirectory: root,
                moduleName: moduleName,
                entryName: entryName
            )
        }
        throw BackendRuntimeError.missingRuntimeLayout(searchedRoots: searchedRoots)
    }
}

enum BackendRuntimeError: Error, CustomStringConvertible {
    case missingRuntimeLayout(searchedRoots: [URL])

    var description: String {
        switch self {
        case .missingRuntimeLayout(let searchedRoots):
            let roots = searchedRoots.map(\.path).joined(separator: ", ")
            return "missing Rivet runtime/petite.boot, runtime/scheme.boot, "
                + "runtime/racket.boot, or res/core.zo under: \(roots)"
        }
    }
}

// The embedded Racket CS runtime is a single instance per process:
// `Sscheme_init` refuses a second boot ("call Sscheme_deinit first to
// terminate"), so the app and the test suite MUST share one backend.
// `startShared()` is idempotent and returns the running backend; a
// deliberate `stop()` allows a fresh start (the process-death lifecycle
// test exercises exactly that cycle).
@MainActor
enum SharedBackend {
    private static var backend: EmbeddedRacketBackend?
    private static var startupError: Error?
    // A second racket_boot in the same iOS process crashed in CI 45930838481.
    // The process owns exactly one boot attempt; fresh boots require a fresh process.
    private static var bootAttempted = false
    private(set) static var retired = false
    private static var stopping = false
    private static var stopTask: Task<Void, Never>?
    private(set) static var started = false

    static func start() {
        guard backend == nil, !started, !stopping, !bootAttempted else { return }
        bootAttempted = true
        startupError = nil
        started = true
        // The VM boot blocks until the server thread is ready (tens of
        // seconds while core.zo loads); never block the calling thread —
        // on the main thread that would hang the app launch itself.
        Task.detached {
            do {
                var config = try BackendRuntime.configuration(
                    moduleName: RivetGeneratedConfig.moduleName,
                    entryName: RivetGeneratedConfig.entryName
                )
                config.diagnosticSink = { record in
                    let line = "rivet-diag [\(record.layer)] \(record.event): \(record.status)\n"
                    FileHandle.standardError.write(line.data(using: .utf8)!)
                }
                let started_backend = EmbeddedRacketBackend(configuration: config)
                // Publish the backend BEFORE `start()`: the start call
                // serves the VM on this thread and never returns, so the
                // handoff must happen first. RPC calls issued meanwhile
                // queue until the boot completes.
                await MainActor.run {
                    SharedBackend.backend = started_backend
                    ApplicationDelegate.orderlyShutdown = { SharedBackend.requestStop() }
                }
                try started_backend.start()
            } catch {
                await MainActor.run {
                    SharedBackend.startupError = error
                    SharedBackend.started = false
                    SharedBackend.retired = true
                }
            }
        }
    }

    // Never enter the synchronous native stop path while startup is in
    // flight. A boot stuck inside Chez cannot be interrupted safely.
    // Retain ownership and prohibit a second process-scoped VM.
    static func requestStop() {
        guard !stopping, let running = backend, running.isReady else { return }
        stopping = true
        ApplicationDelegate.orderlyShutdown = nil
        stopTask = Task {
            // Keep the main actor responsive and retain the sole VM owner
            // until the native thread actually exits.
            await Task.detached { running.stop() }.value
            backend = nil
            started = false
            retired = true
            stopping = false
            stopTask = nil
        }
    }

    static func stop() async {
        requestStop()
        await stopTask?.value
    }

    static var current: EmbeddedRacketBackend? { stopping ? nil : backend }

    /// Waits (bounded) until the detached VM reaches serving state.
    /// Never expose a merely allocated backend after a boot timeout: doing
    /// so makes clients issue RPCs into a VM that may be stuck in libffi.
    /// Nil means startup failed or did not become ready before the deadline.
    @MainActor
    static func waitForStart(timeout: TimeInterval = 180) async -> EmbeddedRacketBackend? {
        guard timeout.isFinite, timeout > 0 else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline && !Task.isCancelled {
            if startupError != nil || stopping || retired { return nil }
            if let running = backend, running.isReady { return running }
            do {
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(200))))
            } catch {
                return nil
            }
        }
        return nil
    }
    static var lastError: Error? { startupError }
}
