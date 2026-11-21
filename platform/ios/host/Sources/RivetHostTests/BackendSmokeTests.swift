import XCTest
@testable import RivetHost
import RivetEmbedding
import RivetRuntime

/// The simulator lifecycle evidence for a standalone iOS host: the
/// portable-bytecode Racket CS must boot inside this app process, serve
/// typed RPCs, and shut down/start orderly. The embedded runtime is a
/// single instance per process (`Sscheme_init` refuses a second boot), so
/// every test shares `SharedBackend` — which is also how the running app
/// itself uses it. The orderly stop/start cycle is what the process-death
/// policy exercises: contract-observable state must be served again after
/// a deliberate stop and fresh boot (in-memory state starts at its
/// documented initial value).
@MainActor
final class BackendSmokeTests: XCTestCase {
    func testBackendBootsAndServesContract() async throws {
        SharedBackend.start()
        let maybeBackend = await SharedBackend.waitForStart()
        let backend = try XCTUnwrap(maybeBackend,
                                    "shared backend failed: \(String(describing: SharedBackend.lastError))")
        let api = RivetAPI(client: backend.client)

        let greeting = try await api.greet(name: "iOS")
        XCTAssertEqual(greeting, "Hello, iOS!")

        let written = try await api.set_counter(41)
        XCTAssertEqual(written, 41)
        let read = try await api.get_counter()
        XCTAssertEqual(read, 41)
    }

    func testOrderlyStopStartServesFreshRuntime() async throws {
        // Stop the shared backend (Sscheme_deinit), boot it again (fresh
        // Sscheme_init), and verify the contract serves with documented
        // initial state — the orderly process-death cycle, end to end.
        SharedBackend.start()
        let before = await SharedBackend.waitForStart()
        let runningBefore = try XCTUnwrap(before)
        _ = try await RivetAPI(client: runningBefore.client).set_counter(7)
        runningBefore.stop()

        SharedBackend.start()
        let after = await SharedBackend.waitForStart(timeout: 180)
        let runningAfter = try XCTUnwrap(after)
        let read = try await RivetAPI(client: runningAfter.client).get_counter()
        XCTAssertEqual(read, 0, "a fresh pb runtime must reset in-memory state")
        let greeting = try await RivetAPI(client: runningAfter.client).greet(name: "restart")
        XCTAssertEqual(greeting, "Hello, restart!")
    }
}
