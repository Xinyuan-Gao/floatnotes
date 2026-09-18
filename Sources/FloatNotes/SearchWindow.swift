import SwiftUI
import AppKit

final class SearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var hits: [SearchHit] = []
    @Published var selected: String?

    func run() {
        hits = NoteSearch.search(query)
        if selected == nil || !hits.contains(where: { $0.id == selected }) {
            selected = hits.first?.id
        }
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    var onOpen: (String) -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索所有笔记…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { openSelected() }
                    .onChange(of: model.query) { _, _ in model.run() }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""; model.run()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if model.hits.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(model.query.isEmpty ? "输入关键词开始搜索" : "没有匹配的笔记")
                        .foregroundStyle(.secondary)
                    if model.query.isEmpty {
                        Text("会同时搜索笔记标题和正文")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.hits, id: \.id) { hit in
                            hitRow(hit)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("\(model.hits.count) 条结果")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("↩ 打开 · esc 关闭")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .frame(width: 520, height: 420)
        .onAppear { focused = true; model.run() }
    }

    private func hitRow(_ hit: SearchHit) -> some View {
        Button {
            model.selected = hit.id
            onOpen(hit.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.id)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !hit.snippet.isEmpty {
                    Text(hit.snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(model.selected == hit.id ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openSelected() {
        if let id = model.selected ?? model.hits.first?.id { onOpen(id) }
    }
}

// MARK: - 窗口

final class SearchWindowController {

    static let shared = SearchWindowController()
    private var window: NSWindow?
    private let model = SearchModel()

    func toggle() {
        if let w = window, w.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        let view = SearchView(
            model: model,
            onOpen: { [weak self] id in
                NoteWindowManager.shared.open(id)
                self?.close()
            },
            onClose: { [weak self] in self?.close() }
        )

        if let w = window {
            w.contentViewController = NSHostingController(rootView: view)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "搜索笔记"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        window = w

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
    }
}
