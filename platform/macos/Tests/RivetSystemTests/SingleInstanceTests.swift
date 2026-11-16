import Darwin
import Foundation
import Testing
@testable import RivetSystem

private func lockPaths(for applicationID: String) -> (persistent: URL, legacy: URL) {
    let manager = FileManager.default
    let name = applicationID + ".lock"
    return (
        manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rivet/InstanceLocks/" + name),
        manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rivet/InstanceLocks/" + name)
    )
}

@Test func singleInstanceHoldsBothLocksAndReleasesOnDeinit() throws {
    let id = "dev.rivet.test.single-instance." + UUID().uuidString
    let paths = lockPaths(for: id)
    defer {
        try? FileManager.default.removeItem(at: paths.persistent)
        try? FileManager.default.removeItem(at: paths.legacy)
    }

    var primary: RivetSingleInstance? = try RivetSingleInstance(applicationID: id)
    #expect(primary?.isPrimary == true)
    #expect(FileManager.default.fileExists(atPath: paths.persistent.path))
    #expect(FileManager.default.fileExists(atPath: paths.legacy.path))

    let secondary = try RivetSingleInstance(applicationID: id)
    #expect(secondary.isPrimary == false)
    primary = nil
    let nextPrimary = try RivetSingleInstance(applicationID: id)
    #expect(nextPrimary.isPrimary == true)
}

@Test func singleInstanceRejectsLegacyOwnerAndRecoversAfterRelease() throws {
    let id = "dev.rivet.test.legacy-instance." + UUID().uuidString
    let paths = lockPaths(for: id)
    try FileManager.default.createDirectory(
        at: paths.legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    defer {
        try? FileManager.default.removeItem(at: paths.persistent)
        try? FileManager.default.removeItem(at: paths.legacy)
    }

    let legacyFD = Darwin.open(paths.legacy.path, O_CREAT | O_RDWR | O_CLOEXEC,
                               S_IRUSR | S_IWUSR)
    #expect(legacyFD >= 0)
    guard legacyFD >= 0 else { return }
    #expect(flock(legacyFD, LOCK_EX | LOCK_NB) == 0)
    do {
        let candidate = try RivetSingleInstance(applicationID: id)
        #expect(candidate.isPrimary == false)
    }
    _ = flock(legacyFD, LOCK_UN)
    _ = Darwin.close(legacyFD)

    let primary = try RivetSingleInstance(applicationID: id)
    #expect(primary.isPrimary == true)
}

@Test func singleInstancePersistentLockSurvivesCacheEntryRemoval() throws {
    let id = "dev.rivet.test.cache-eviction." + UUID().uuidString
    let paths = lockPaths(for: id)
    defer {
        try? FileManager.default.removeItem(at: paths.persistent)
        try? FileManager.default.removeItem(at: paths.legacy)
    }

    let primary = try RivetSingleInstance(applicationID: id)
    #expect(primary.isPrimary == true)
    // Simulate the old cache inode being unlinked while the original FD
    // remains open; the Application Support lock still prevents split brain.
    try FileManager.default.removeItem(at: paths.legacy)
    let second = try RivetSingleInstance(applicationID: id)
    #expect(second.isPrimary == false)
}
