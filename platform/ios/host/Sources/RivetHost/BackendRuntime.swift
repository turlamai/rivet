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
