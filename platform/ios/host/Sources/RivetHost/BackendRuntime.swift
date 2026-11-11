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
    private(set) static var started = false

    static func start() {
        guard backend == nil, !started else { return }
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
                    ApplicationDelegate.orderlyShutdown = { started_backend.stop() }
                }
                try started_backend.start()
            } catch {
                await MainActor.run {
                    SharedBackend.startupError = error
                    SharedBackend.started = false
                }
            }
        }
    }

    static func stop() {
        backend?.stop()
        backend = nil
        started = false
    }

    static var current: EmbeddedRacketBackend? { backend }

    /// Waits (bounded) for the detached boot to finish AND the embedded
    /// VM to reach its serving state, returning the running backend — or
    /// nil when startup failed (see `lastError`).
    @MainActor
    static func waitForStart(timeout: TimeInterval = 180) async -> EmbeddedRacketBackend? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = startupError { _ = error; return nil }
            if let running = backend, running.isReady { return running }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return backend
    }
    static var lastError: Error? { startupError }
}
