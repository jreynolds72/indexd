import Foundation
import Dispatch
import Darwin

final class LocalLibraryWatcher {
    private struct DirectoryWatch {
        let fileDescriptor: Int32
        let source: DispatchSourceFileSystemObject
    }

    private let queue = DispatchQueue(label: "com.indexd.local-library-watcher", qos: .utility)
    private var watchesByPath: [String: DirectoryWatch] = [:]
    private var pendingSignal: DispatchWorkItem?
    private let onDebouncedChange: @Sendable () -> Void
    private let debounceInterval: TimeInterval

    init(
        debounceInterval: TimeInterval = 0.8,
        onDebouncedChange: @escaping @Sendable () -> Void
    ) {
        self.debounceInterval = debounceInterval
        self.onDebouncedChange = onDebouncedChange
    }

    deinit {
        invalidate()
    }

    func updateRoots(_ roots: [URL]) {
        queue.async { [weak self] in
            self?.rebuildWatches(for: roots)
        }
    }

    func invalidate() {
        queue.sync {
            pendingSignal?.cancel()
            pendingSignal = nil
            cancelAllWatches()
        }
    }

    private func rebuildWatches(for roots: [URL]) {
        let directories = monitoredDirectories(from: roots)
        let targetPaths = Set(directories.map(\.path))
        let currentPaths = Set(watchesByPath.keys)

        for removedPath in currentPaths.subtracting(targetPaths) {
            cancelWatch(atPath: removedPath)
        }

        for directoryURL in directories {
            let path = directoryURL.path
            if watchesByPath[path] != nil {
                continue
            }
            addWatch(for: directoryURL)
        }
    }

    private func monitoredDirectories(from roots: [URL]) -> [URL] {
        var results: [URL] = []
        var seen = Set<String>()
        let fileManager = FileManager.default

        for root in roots {
            let standardizedRoot = root.standardizedFileURL
            guard fileManager.fileExists(atPath: standardizedRoot.path) else { continue }

            if seen.insert(standardizedRoot.path).inserted {
                results.append(standardizedRoot)
            }

            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard let isDirectory = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDirectory == true else {
                    continue
                }
                let standardized = url.standardizedFileURL
                if seen.insert(standardized.path).inserted {
                    results.append(standardized)
                }
            }
        }

        return results
    }

    private func addWatch(for directoryURL: URL) {
        let fd = open(directoryURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link, .revoke],
            queue: queue
        )

        let path = directoryURL.path
        source.setEventHandler { [weak self] in
            self?.scheduleSignal()
        }
        source.setCancelHandler {
            close(fd)
        }

        watchesByPath[path] = DirectoryWatch(fileDescriptor: fd, source: source)
        source.resume()
    }

    private func scheduleSignal() {
        pendingSignal?.cancel()
        let workItem = DispatchWorkItem { [onDebouncedChange] in
            onDebouncedChange()
        }
        pendingSignal = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func cancelWatch(atPath path: String) {
        guard let watch = watchesByPath.removeValue(forKey: path) else { return }
        watch.source.cancel()
    }

    private func cancelAllWatches() {
        let all = watchesByPath.keys
        for path in all {
            cancelWatch(atPath: path)
        }
    }
}
