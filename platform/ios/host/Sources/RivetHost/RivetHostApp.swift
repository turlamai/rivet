import SwiftUI
import RivetEmbedding
import RivetRuntime

@main
struct RivetHostApp: App {
    @UIApplicationDelegateAdaptor(ApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .task {
                    model.start()
                }
                .onChange(of: scenePhase) { phase in
                    model.handleScenePhase(phase)
                }
        }
    }
}

/// Every termination path — scene teardown, app switcher removal, OS
/// shutdown — passes through a single orderly-stop hook, so the embedded
/// backend shuts down cleanly. iOS delivers `willTerminate` on the main
/// thread while the process still has time to finish IO.
@MainActor
final class ApplicationDelegate: NSObject, UIApplicationDelegate {
    static var orderlyShutdown: (() -> Void)?

    func applicationWillTerminate(_ application: UIApplication) {
        Self.orderlyShutdown?()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Starting embedded Racket CS…"
    @Published var count: Int64 = 0
    @Published var ready = false

    private var startupTask: Task<Void, Never>?

    func start() {
        // The detached boot publishes SharedBackend.current on the main
        // actor *later*. Reading it synchronously here races that handoff,
        // and sending an RPC before isReady can wait forever on a hung VM.
        guard !ready, startupTask == nil else { return }
        status = "Starting embedded Racket CS…"
        SharedBackend.start()

        startupTask = Task { [weak self] in
            defer { self?.startupTask = nil }
            guard let self else { return }

            guard let backend = await SharedBackend.waitForStart() else {
                self.ready = false
                if let error = SharedBackend.lastError {
                    self.status = "Backend startup failed: \(error)"
                } else {
                    // The test suite fails rather than treating an allocated
                    // backend as ready when the pb VM stalls in S_ffi_closure.
                    self.status = "Embedded Racket CS did not become ready within 180 seconds"
                }
                return
            }

            do {
                let api = RivetAPI(client: backend.client)
                let initialCount = try await api.get_counter()
                self.count = initialCount
                self.ready = true
                self.status = "Embedded Racket CS is ready"
            } catch {
                self.ready = false
                self.status = "Backend error: \(error)"
            }
        }
    }

    /// The backend keeps serving across background transitions; iOS suspends
    /// the process rather than expecting the app to tear its state down.
    func handleScenePhase(_ phase: ScenePhase) {
        // Reserved for product-owned background work (refresh budgets,
        // state snapshots). The embedded backend lifecycle is deliberately
        // not tied to scene phases.
    }

    func increment() {
        guard let backend = SharedBackend.current, ready else { return }
        let next = count + 1

        Task {
            do {
                let api = RivetAPI(client: backend.client)
                count = try await api.set_counter(next)
            } catch {
                status = "State error: \(error)"
            }
        }
    }
}
