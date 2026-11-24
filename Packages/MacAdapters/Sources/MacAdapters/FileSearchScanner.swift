import Foundation
import Darwin

/// 每个detached worker独占此实例；仅目录描述符与stat元数据，不读取文件正文。
final class FileSearchScanner {
    private let query: String
    private let token: UUID
    private let limits: FileSearchLimits
    private let resultLimit: Int
    private var results: [FileSearchResult] = []
    private var ids: Set<String> = []
    private var scopes: [FileSearchScopeSummary] = []
    private var scanned = 0
    private var reasons: Set<FileSearchTruncationReason> = []
    private var stop = false
    init(query: String, token: UUID, limits: FileSearchLimits, resultLimit: Int) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        self.token = token; self.limits = limits; self.resultLimit = resultLimit
    }
    func run(roots: [URL]) throws -> FileSearchReport {
        try Task.checkCancellation()
        guard !query.isEmpty else {
            return FileSearchReport(requestID: token, results: [], scopes: roots.map {
                FileSearchScopeSummary(requestedURL: $0, resolvedURL: nil, status: .notScanned, scannedItems: 0, inaccessibleItems: 0)
            }, scannedItems: 0, truncationReasons: [])
        }
        for url in roots {
            try Task.checkCancellation()
            if stop {
                scopes.append(.init(requestedURL: url, resolvedURL: nil, status: .notScanned, scannedItems: 0, inaccessibleItems: 0)); continue
            }
            let scope: FileSearchRootIdentity, descriptor: Int32
            do { (scope, descriptor) = try FileSearchPOSIX.prepare(url) }
            catch let error as FileSearchPOSIX.RootFailure {
                scopes.append(.init(requestedURL: url, resolvedURL: nil, status: error.status, scannedItems: 0, inaccessibleItems: 0)); continue
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                scopes.append(.init(requestedURL: url, resolvedURL: nil, status: .unavailable, scannedItems: 0, inaccessibleItems: 0)); continue
            }
            let before = scanned, resultStart = results.count
            var inaccessible = 0
            do {
                try walk(fd: descriptor, scope: scope, components: [], chain: [], depth: 0, inaccessible: &inaccessible)
                let verified = try FileSearchPOSIX.verifiedRoot(scope); Darwin.close(verified)
                scopes.append(.init(requestedURL: url, resolvedURL: scope.canonicalURL, status: inaccessible == 0 ? .available : .partiallyUnavailable, scannedItems: scanned - before, inaccessibleItems: inaccessible))
                Darwin.close(descriptor)
            } catch is CancellationError { Darwin.close(descriptor); throw CancellationError() }
            catch {
                for item in results[resultStart...] { ids.remove(item.id) }
                results.removeSubrange(resultStart..<results.count)
                scopes.append(.init(requestedURL: url, resolvedURL: scope.canonicalURL, status: .changed, scannedItems: scanned - before, inaccessibleItems: inaccessible))
                Darwin.close(descriptor)
            }
        }
        try Task.checkCancellation()
        let ordered = results.sorted {
            let left = $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            let right = $1.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            return left == right ? $0.url.path < $1.url.path : left < right
        }
        return FileSearchReport(requestID: token, results: ordered, scopes: scopes, scannedItems: scanned, truncationReasons: reasons)
    }
    private func walk(fd: Int32, scope: FileSearchRootIdentity, components: [String],
                      chain: [FileSearchDirectoryIdentity], depth: Int, inaccessible: inout Int) throws {
        try Task.checkCancellation()
        let duplicate = Darwin.fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { inaccessible += 1; return }
        guard let directory = Darwin.fdopendir(duplicate) else { Darwin.close(duplicate); inaccessible += 1; return }
        defer { Darwin.closedir(directory) }
        while !stop {
            try Task.checkCancellation()
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                if errno != 0 { inaccessible += 1 }
                return
            }
            let capacity = Int(entry.pointee.d_namlen) + 1
            var raw = entry.pointee.d_name
            let decoded = withUnsafePointer(to: &raw) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(validatingUTF8: $0) }
            }
            if decoded == "." || decoded == ".." { continue }
            if scanned >= limits.maxScannedItems { reasons.insert(.scannedItemLimit); stop = true; return }
            scanned += 1
            guard let name = decoded, FileSearchPOSIX.validComponent(name) else { continue }
            var value = stat()
            guard Darwin.fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { inaccessible += 1; continue }
            if FileSearchPOSIX.hidden(name, value) || FileSearchPOSIX.isSymbolicLink(value) { continue }
            let relative = components + [name]
            let url = relative.reduce(scope.canonicalURL) { $0.appendingPathComponent($1) }
            if FileSearchPOSIX.isDirectory(value) {
                if FileSearchPOSIX.package(url) { continue }
                guard depth < limits.maxDepth else { reasons.insert(.depthLimit); continue }
                let child = Darwin.openat(fd, name, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { inaccessible += 1; continue }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0, FileSearchPOSIX.isDirectory(opened),
                      FileSearchDirectoryIdentity(opened) == FileSearchDirectoryIdentity(value) else {
                    Darwin.close(child); inaccessible += 1; continue
                }
                do { try walk(fd: child, scope: scope, components: relative, chain: chain + [.init(opened)], depth: depth + 1, inaccessible: &inaccessible) }
                catch { Darwin.close(child); throw error }
                Darwin.close(child)
            } else if FileSearchPOSIX.isRegularFile(value) {
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard folded.contains(query) else { continue }
                let id = "file." + FileSearchPOSIX.fingerprint(url.path)
                guard !ids.contains(id) else { continue }
                guard results.count < resultLimit else { reasons.insert(.resultLimit); stop = true; return }
                let identity = FileSearchObjectIdentity(value)
                let revision = FileSearchPOSIX.fingerprint(scope.identity.revision + "|" + chain.map(\.revision).joined(separator: "/") + "|" + identity.revision)
                results.append(FileSearchResult(id: id, title: name, url: url, objectRevision: revision,
                    queryToken: token, scope: scope, relativeComponents: relative, directoryChain: chain, identity: identity))
                ids.insert(id)
            }
        }
    }
}
