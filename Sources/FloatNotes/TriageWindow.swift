import SwiftUI
import AppKit

// MARK: - 模型

final class TriageModel: ObservableObject {

    @Published var dailyID: String = DailyNote.todayID()
    @Published var header: String = ""
    @Published var entries: [DailyEntry] = []
    @Published var selected: Set<String> = []
    @Published var topicNotes: [String] = []
    @Published var targetNote: String = ""
    @Published var newNoteName: String = ""
    @Published var status: String = ""
    @Published var statusIsError: Bool = false

    var dateLabel: String {
        dailyID.replacingOccurrences(of: " 今日笔记", with: "")
    }

    // MARK: 读取

    func reload() {
        dailyID = DailyNote.todayID()
        let parsed = DailyNoteTriage.parse(NoteStore.shared.load(dailyID))
        header = parsed.header
        entries = parsed.entries
        selected = selected.intersection(Set(entries.map(\.id)))

        topicNotes = NoteStore.shared.allNoteIDs().filter { $0 != dailyID }
        if targetNote.isEmpty || !topicNotes.contains(targetNote) {
            targetNote = topicNotes.first ?? ""
        }

        if status.isEmpty {
            status = entries.isEmpty ? "今天还没有摘录。" : "勾选条目，选好目标笔记，然后归档。"
        }
    }

    func setStatus(_ s: String, error: Bool = false) {
        status = s
        statusIsError = error
    }

    // MARK: 选择

    func binding(for entry: DailyEntry) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.selected.contains(entry.id) ?? false },
            set: { [weak self] on in
                guard let self else { return }
                if on { self.selected.insert(entry.id) } else { self.selected.remove(entry.id) }
            }
        )
    }

    func selectAll() { selected = Set(entries.map(\.id)) }
    func clearSelection() { selected.removeAll() }

    private var chosen: [DailyEntry] {
        entries.filter { selected.contains($0.id) }
    }

    // MARK: 归档

    func archiveSelected() {
        let picked = chosen
        guard !picked.isEmpty else {
            setStatus("先勾选要归档的条目。", error: true); return
        }

        let target: String
        let newName = newNoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty {
            target = NoteStore.shared.uniqueNoteID(base: SelectionNote.sanitize(newName))
            NoteStore.shared.ensureNote(target)
        } else if !targetNote.isEmpty {
            target = targetNote
        } else {
            setStatus("请选择一个目标笔记，或填一个新的名字。", error: true); return
        }

        let result = DailyNoteTriage.archive(
            entries: picked, from: dailyID, to: target,
            dateString: DailyNote.dateString()
        )

        // 打开着的窗口要跟着更新（force：文件是本次正式改写的，优先级最高）
        NoteWindowManager.shared.reloadFromDisk([dailyID, target], force: true)

        newNoteName = ""
        selected.removeAll()
        reload()
        setStatus(result.failed == 0
                  ? "已归档 \(result.moved) 条 → \(target)"
                  : "归档 \(result.moved) 条，但有 \(result.failed) 条写入失败",
                  error: result.failed > 0)
    }

    func deleteSelected() {
        let picked = chosen
        guard !picked.isEmpty else {
            setStatus("先勾选要删除的条目。", error: true); return
        }
        let content = NoteStore.shared.load(dailyID)
        let cleaned = DailyNoteTriage.remove(entries: picked, from: content)
        NoteStore.shared.replaceAll(dailyID, with: cleaned)
        NoteWindowManager.shared.reloadFromDisk([dailyID], force: true)

        let n = picked.count
        selected.removeAll()
        reload()
        setStatus("已删除 \(n) 条。")
    }
}

// MARK: - 视图

struct TriageView: View {

    @ObservedObject var model: TriageModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if model.entries.isEmpty {
                emptyState
            } else {
                entryList
            }

            Divider()
            bottomBar
        }
        .frame(width: 640, height: 580)
        .onAppear { model.reload() }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("今日笔记 · \(model.dateLabel)")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(model.entries.count) 条待整理")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("全选") { model.selectAll() }
                .buttonStyle(.link).font(.caption)
            Button("取消选择") { model.clearSelection() }
                .buttonStyle(.link).font(.caption)
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("重新读取今日笔记")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("今天的摘录都整理完了")
                .foregroundStyle(.secondary)
            Text("读文章时按 ⌥⌘E，摘录会自动攒到这里。")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.entries) { entry in
                    row(entry)
                    Divider().padding(.leading, 44)
                }
            }
        }
    }

    private func row(_ entry: DailyEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: model.binding(for: entry))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if !entry.time.isEmpty {
                        Text(entry.time)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                if !entry.preview.isEmpty {
                    Text(entry.preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let urlString = entry.url, let url = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("打开原文：\(urlString)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture { model.binding(for: entry).wrappedValue.toggle() }
    }

    private var bottomBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Text("归档到")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                Picker("", selection: $model.targetNote) {
                    if model.topicNotes.isEmpty {
                        Text("（还没有别的笔记）").tag("")
                    }
                    ForEach(model.topicNotes, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 250)

                Text("或新建").font(.system(size: 12)).foregroundStyle(.secondary)

                TextField("主题笔记名…", text: $model.newNoteName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 168)

                Spacer()
            }

            HStack(spacing: 10) {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
                    .lineLimit(1)

                Spacer()

                Button("删除选中") { model.deleteSelected() }
                    .disabled(model.selected.isEmpty)

                Button("归档选中（\(model.selected.count)）") { model.archiveSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - 窗口

final class TriageWindowController {

    static let shared = TriageWindowController()
    private var window: NSWindow?
    private let model = TriageModel()

    func toggle() {
        if let w = window, w.isVisible { close() } else { show() }
    }

    func show() {
        let view = TriageView(model: model)
        if let w = window {
            w.contentViewController = NSHostingController(rootView: view)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "整理今日笔记"
        w.styleMask = [.titled, .closable, .resizable]
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.center()
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
}
