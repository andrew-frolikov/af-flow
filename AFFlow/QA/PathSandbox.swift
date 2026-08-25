import Foundation

enum PathSandboxError: LocalizedError {
    case pathOutsideRoot(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideRoot(let p):
            return "Path '\(p)' is outside the meeting archive."
        }
    }
}

enum PathSandbox {
    static func resolveSafe(_ relative: String, root: URL) throws -> URL {
        let candidate: URL
        if relative.isEmpty || relative == "." {
            candidate = root
        } else if relative.hasPrefix("/") {
            throw PathSandboxError.pathOutsideRoot(relative)
        } else {
            candidate = root.appendingPathComponent(relative)
        }

        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootResolved = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootResolved.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        if resolved.path == rootPath || resolved.path.hasPrefix(rootPrefix) {
            return resolved
        }
        throw PathSandboxError.pathOutsideRoot(relative)
    }
}
