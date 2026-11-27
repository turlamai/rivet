import XCTest
@testable import RivetHost
import RivetEmbedding
import RivetRuntime

/// The simulator gate uses one VM per process. A second boot crashed in CI.
/// Process relaunch must be verified in a separate fresh test invocation.
@MainActor
final class BackendSmokeTests: XCTestCase {
    func testInvalidAndCancelledReadinessWaitsFailClosed() async {
        for timeout in [0.0, -1.0, Double.infinity, Double.nan] {
            let result = await SharedBackend.waitForStart(timeout: timeout)
            XCTAssertNil(result, "invalid deadlines must not return a backend")
        }

        // This task inherits MainActor. Cancel before yielding so the
        // cancellation is deterministic even when the host is already ready.
        let wait = Task {
            await SharedBackend.waitForStart(timeout: 180)
        }
        wait.cancel()
        let result = await wait.value
        XCTAssertNil(result, "cancelled readiness waits must fail closed")
    }

    func testBackendBootsAndServesContract() async throws {
        SharedBackend.start()
        let maybeBackend = await SharedBackend.waitForStart()
        let backend = try XCTUnwrap(maybeBackend,
                                    "embedded VM did not become ready within 180s; startup error: \(String(describing: SharedBackend.lastError))")
        XCTAssertTrue(backend.isReady, "do not issue RPCs before the embedded VM is serving")
        SharedBackend.start()
        XCTAssertTrue(SharedBackend.current === backend, "start must preserve the single VM owner")
        let api = RivetAPI(client: backend.client)

        let greeting = try await api.greet(name: "iOS")
        XCTAssertEqual(greeting, "Hello, iOS!")

        let written = try await api.set_counter(41)
        XCTAssertEqual(written, 41)
        let read = try await api.get_counter()
        XCTAssertEqual(read, 41)
    }

    func testOrderlyStopRetiresProcessRuntime() async throws {
        // Verify orderly teardown and reject unsafe same-process reboot.
        SharedBackend.start()
        let before = await SharedBackend.waitForStart()
        let runningBefore = try XCTUnwrap(before,
                                          "embedded VM was not serving before the stop/restart test")
        XCTAssertTrue(runningBefore.isReady)
        _ = try await RivetAPI(client: runningBefore.client).set_counter(7)
        // Stop through the shared owner, not the bare backend: stopping the
        // backend alone leaves SharedBackend.started=true and its stale
        // reference allocated, so a subsequent start() becomes a no-op.
        SharedBackend.requestStop()
        XCTAssertNil(SharedBackend.current, "a stopping VM must not accept new RPCs")
        SharedBackend.start()
        XCTAssertNil(SharedBackend.current, "do not publish a second VM before teardown completes")
        await SharedBackend.stop()
        XCTAssertFalse(SharedBackend.started)

        XCTAssertTrue(SharedBackend.retired)
        SharedBackend.start()
        let after = await SharedBackend.waitForStart(timeout: 180)
        XCTAssertNil(after, "a retired process must not boot Racket again")
        XCTAssertNil(SharedBackend.current)
        XCTAssertFalse(SharedBackend.started)
    }
}
