import CoreServices
import Foundation

/// Recursive FSEvents watcher for file changes under a directory (callers filter paths).
/// Events are coalesced by FSEvents (latency) and delivered on `queue`.
final class LogWatcher {
    enum Change {
        case files(Set<String>)
        case rescan
    }

    private var stream: FSEventStreamRef?
    private let root: String
    private let queue: DispatchQueue
    private let handler: (Change) -> Void

    init(root: String, queue: DispatchQueue, handler: @escaping (Change) -> Void) {
        self.root = root
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changed = Set<String>()
            var rescan = false
            for i in 0..<count {
                let f = eventFlags[i]
                if f & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 {
                    rescan = true
                }
                if i < array.count { changed.insert(array[i]) }
            }
            if rescan { watcher.handler(.rescan) }
            if !changed.isEmpty { watcher.handler(.files(changed)) }
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // seconds of coalescing; Claude streams many lines per second
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
