import Foundation
import Testing
@testable import RivetSystem

@MainActor
@Test func activationRouterReplaysEarlyURLsInArrivalOrder() {
    let router = RivetActivationRouter()
    let first = URL(string: "rivet://open/first")!
    let second = URL(fileURLWithPath: "/tmp/rivet-second.txt")
    let third = URL(string: "rivet://open/third")!
    var received: [[URL]] = []

    router.handle([first, second])
    router.handle([])
    router.handle([third])
    #expect(router.pendingURLCount == 3)
    #expect(router.droppedURLCount == 0)

    router.onURLs = { received.append($0) }
    #expect(router.pendingURLCount == 0)
    #expect(received == [[first, second, third]])

    let fourth = URL(string: "rivet://open/fourth")!
    router.handle([fourth])
    #expect(received == [[first, second, third], [fourth]])
}

@MainActor
@Test func activationRouterRetainsBoundedLatestEvents() {
    let router = RivetActivationRouter()
    let total = RivetActivationRouter.pendingLimit + 7
    let urls = (0..<total).map { URL(string: "rivet://open/\($0)")! }
    router.handle(urls)

    #expect(router.pendingURLCount == RivetActivationRouter.pendingLimit)
    #expect(router.droppedURLCount == 7)

    var received: [URL] = []
    router.onURLs = { received.append(contentsOf: $0) }
    #expect(received == Array(urls.suffix(RivetActivationRouter.pendingLimit)))
    #expect(router.pendingURLCount == 0)
    #expect(router.droppedURLCount == 7)
}

@MainActor
@Test func activationRouterHandlesLateReplacementAndReentrantDelivery() {
    let router = RivetActivationRouter()
    let one = URL(string: "rivet://one")!
    let two = URL(string: "rivet://two")!
    var received: [URL] = []
    router.handle([one])
    router.onURLs = { batch in
        received.append(contentsOf: batch)
        // An event received during first drain must be delivered once.
        if received.count == 1 {
            router.handle([two])
        }
    }
    #expect(received == [one, two])
    #expect(router.pendingURLCount == 0)

    router.onURLs = nil
    router.handle([one])
    #expect(router.pendingURLCount == 1)

    router.onURLs = { received.append(contentsOf: $0) }
    #expect(received == [one, two, one])
    #expect(router.pendingURLCount == 0)
}
