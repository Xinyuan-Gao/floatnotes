import CoreServices
import AppKit

/// 监听笔记目录的外部改动（Obsidian / VS Code / Finder 改了文件 → 打开的窗口自动刷新）。
///
/// 关键难点是**避免自激**：本 App 自己落盘也会触发 FSEvents，
/// 所以 NoteStore 会记录「刚才是谁写的」，这里只对非自己写的事件作出反应。
final class NoteWatcher {

    private var stream: FSEventStreamRef?
    private let path: String
    private let queue = DispatchQueue(label: "com.xy.floatnotes.watcher")
    private var debounce: DispatchWorkItem?
    private var onExternalChange: ((Set<String>) -> Void)?

    /// 自己写盘的静默期
    private let selfWriteGrace: TimeInterval = 2.0

    init(path: String) {
        self.path = path
    }

    func start(onExternalChange: @escaping (Set<String>) -> Void) {
        self.onExternalChange = onExternalChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<NoteWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handle(paths: NoteWatcher.decodePaths(eventPaths, count: numEvents))
        }

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,                       // 延迟：把连续写入合并
            flags
        ) else {
            NSLog("[NoteWatcher] FSEventStreamCreate 失败")
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            NSLog("[NoteWatcher] FSEventStreamStart 失败")
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    // MARK: - 事件路径解码
    //
    // 没有设置 kFSEventStreamCreateFlagUseCFTypes 时，
    // eventPaths 是一个 C 数组 char*[numEvents]，必须按指针解引用，
    // 不能当成 NSArray（那样会直接段错误）。

    private static func decodePaths(_ raw: UnsafeMutableRawPointer, count: Int) -> [String] {
        guard count > 0 else { return [] }
        let cPaths = raw.assumingMemoryBound(to: UnsafeMutablePointer<CChar>?.self)
        var out: [String] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            if let p = cPaths[i] {
                out.append(String(cString: p))
            }
        }
        return out
    }

    // MARK: - 事件处理

    private func handle(paths: [String]) {
        // 只关心 .md
        let mdPaths = paths.filter { $0.hasSuffix(".md") }
        guard !mdPaths.isEmpty else { return }

        // 过滤掉自己刚写的
        let now = Date()
        let external = mdPaths.filter { p in
            guard let when = NoteStore.shared.lastSelfWrite(for: p) else { return true }
            return now.timeIntervalSince(when) > selfWriteGrace
        }
        guard !external.isEmpty else { return }

        let ids = Set(external.map {
            URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
        })

        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onExternalChange?(ids)
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
