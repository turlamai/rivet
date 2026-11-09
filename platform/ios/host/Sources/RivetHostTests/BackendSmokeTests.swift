import XCTest
@testable import RivetHost
import RivetEmbedding
import RivetRuntime

/// The simulator lifecycle evidence for a standalone iOS host: the
/// portable-bytecode Racket CS must boot inside this app process, serve
/// typed RPCs, and shut down orderly — with no JIT and no executable
/// memory, which is the App Store constraint the pb runtime exists for.
final class BackendSmokeTests: XCTestCase {
    func testBackendBootsAndServesContract() async throws {
        let configuration = try BackendRuntime.configuration(
            moduleName: RivetGeneratedConfig.moduleName,
            entryName: RivetGeneratedConfig.entryName
        )
        let backend = EmbeddedRacketBackend(configuration: configuration)
        try backend.start()
        defer { backend.stop() }

        let api = RivetAPI(client: backend.client)

        let greeting = try await api.greet(name: "iOS")
        XCTAssertEqual(greeting, "Hello, iOS!")

        let written = try await api.set_counter(41)
        XCTAssertEqual(written, 41)
        let read = try await api.get_counter()
        XCTAssertEqual(read, 41)
    }

    func testBackendRestartsAfterOrderlyStop() async throws {
        // Process-death policy: contract-observable state must come back
        // identically after an orderly backend stop/start cycle.
        func bootAndReadCounter() async throws -> Int64 {
            let configuration = try BackendRuntime.configuration(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: configuration)
            try backend.start()
            defer { backend.stop() }
            return try await RivetAPI(client: backend.client).get_counter()
        }

        let first = try await bootAndReadCounter()
        let second = try await bootAndReadCounter()
        XCTAssertEqual(first, second)
    }
}
