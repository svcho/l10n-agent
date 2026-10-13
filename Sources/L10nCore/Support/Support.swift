import CryptoKit
import Foundation

public enum L10nError: Error, CustomStringConvertible, Equatable {
    case catalogParse(path: String, message: String)
    case config(String)
    case notFound(String)
    case translator(String)
    case planConflict(String)
    case invalidArgument(String)
    case lockBusy(String)

    public var description: String {
        switch self {
        case .catalogParse(let path, let message): return "Could not parse \(path): \(message)"
        case .config(let message): return "Configuration error: \(message)"
        case .notFound(let message): return message
        case .translator(let message): return "Translator error: \(message)"
        case .planConflict(let message): return "Plan conflict: \(message)"
        case .invalidArgument(let message): return message
        case .lockBusy(let path): return "Another l10n-agent process is modifying this project (lock: \(path))."
        }
    }
}

public enum AtomicFile {
    /// Writes via a temporary file in the same directory and renames it into place.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    public static func write(_ string: String, to url: URL) throws {
        try write(Data(string.utf8), to: url)
    }
}

/// Advisory, process-scoped lock using `flock`. The kernel releases it when the
/// process exits, so a crash or Ctrl-C never leaves a stale lock behind.
public final class ProjectLock {
    private let descriptor: Int32
    public let path: String

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    public static func acquire(root: URL) throws -> ProjectLock {
        let directory = root.appendingPathComponent(".l10n-agent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw L10nError.lockBusy(path) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw L10nError.lockBusy(path)
        }
        return ProjectLock(descriptor: descriptor, path: path)
    }

    public static func withLock<T>(root: URL, _ body: () throws -> T) throws -> T {
        let lock = try acquire(root: root)
        defer { lock.release() }
        return try body()
    }

    public static func withLock<T>(root: URL, _ body: () async throws -> T) async throws -> T {
        let lock = try acquire(root: root)
        defer { lock.release() }
        return try await body()
    }

    public func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum Hashing {
    public static func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func shortHash(_ string: String) -> String {
        String(sha256(string).prefix(12))
    }
}

public enum PathUtil {
    public static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Resolves `path` against `root` and rejects anything that escapes it.
    public static func resolveInside(_ path: String, root: URL) throws -> URL {
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard isInside(candidate.path, rootPath) else {
            throw L10nError.invalidArgument("Path \(path) is outside the project root \(rootPath)")
        }
        // Symlinks can point outside the root: resolve the deepest existing ancestor.
        var existing = candidate
        var remainder: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            remainder.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in remainder { resolved.appendPathComponent(component) }
        guard isInside(resolved.path, root.resolvingSymlinksInPath().path) else {
            throw L10nError.invalidArgument("Path \(path) resolves outside the project root \(rootPath)")
        }
        return candidate
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// A Swift source file's text, keeping track of a UTF-8 byte order mark so rewrites
/// preserve it.
public struct SourceText: Equatable, Sendable {
    public var text: String
    public var hasBOM: Bool

    public init(text: String, hasBOM: Bool) {
        self.text = text
        self.hasBOM = hasBOM
    }

    public static func read(_ url: URL) throws -> SourceText {
        let data = try Data(contentsOf: url)
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = data.starts(with: bom)
        let body = hasBOM ? data.dropFirst(3) : data[...]
        guard let text = UTF8Text.decode(Array(body)) else {
            throw L10nError.invalidArgument("\(url.path) is not valid UTF-8")
        }
        return SourceText(text: text, hasBOM: hasBOM)
    }

    public func write(to url: URL) throws {
        var data = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(Data(text.utf8))
        try AtomicFile.write(data, to: url)
    }
}

enum UTF8Text {
    /// Strict UTF-8 decoding that keeps every scalar (unlike `String(bytes:encoding:)`,
    /// which drops a leading U+FEFF).
    static func decode(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        return text.utf8.elementsEqual(bytes) ? text : nil
    }
}
