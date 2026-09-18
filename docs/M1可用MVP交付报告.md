# M1 可用 MVP 交付报告

> 日期：2026-09-18
> 目标：在已验证的 M0 spike 基础上，补齐到「能真正替换掉分屏记笔记」的可用版本。
> 结论：**M1 完成，全部自动化检查通过。**

---

## 一、M1 新增了什么

| # | 功能 | 状态 | 说明 |
|---|---|---|---|
| 1 | **设置面板** | ✅ | SwiftUI 承载，6 个分组：置顶行为 / 启动按钮 / 启动 / 编辑器 / 存储 / 快捷键 |
| 2 | **盖住菜单栏开关** | ✅ | 取代 M0 里硬编码的层级，可在「普通置顶」与「盖住菜单栏+Dock」之间切换，实时生效 |
| 3 | **悬浮球贴边吸附** | ✅ | 拖动松手自动吸附到设置指定的那一侧，纵向位置记忆；双击直接新建笔记 |
| 4 | **全部收起** | ✅ | 所有笔记压成 30pt 细栏；启动时可选择自动收起，防止窗口泛滥 |
| 5 | **图片粘贴** | ✅ | 粘贴/拖入图片 → 落盘到附件目录 → 用 `floatnotes://` 自定义 scheme 显示 |
| 6 | **斜杠菜单中文化** | ✅ | 接入 BlockNote 官方 `zh` 字典 |
| 7 | **表格 / 折叠块** | ✅ | 确认已在默认 schema 中，无需额外配置 |
| 8 | **会话恢复** | ✅ | 记住退出时打开的笔记，重启原样恢复；配合 0.4s 防抖 + 原子写 |
| 9 | **笔记删除** | ✅ | 菜单栏最近笔记 → 子菜单 → 删除（走废纸篓，可恢复） |
| 10 | **内存诊断** | ✅ | 菜单栏可随时查看常驻内存与每窗口开销 |
| 11 | **开机自启** | ✅ | `SMAppService`，带状态说明（未放 /Applications 时会提示） |
| 12 | **首次启动引导** | ✅ | 一次性的说明弹窗，跳过则不重复 |

---

## 二、自动化验证结果

一条命令跑完全链路，**PASS ✅**：

```bash
cd floatnotes
"./dist/悬浮笔记.app/Contents/MacOS/FloatNotes" --selftest
```

```
[selftest] 基线内存 60.8 MB
[selftest] 阶段2 · 写入测试 Markdown
[selftest] 阶段3 · DOM 探针
[selftest] S3 焦点: 前=DSH Desktop 后=DSH Desktop → 未打断 ✅
[selftest] 阶段5 · 往返幂等性
[selftest] 幂等: 一致 ✅
[selftest] 阶段7 · 图片粘贴链路
[editor] 附件已保存 0004F2E4-....png（70 字节）
[selftest] 图片链路: {"ok":true,"width":1,"height":1,"src":"floatnotes://media/..."}
[selftest] 附件经 floatnotes:// 加载成功，尺寸 1×1
[selftest] 阶段8 · 设置与收起
[selftest] 层级设置: cover=true→statusBar / false→floating
[selftest] 全部收起: 收起高=30 展开高=340
[selftest] 阶段9 · 多窗口内存量化
[selftest] 内存: 5 窗口 | 基线 60.8 MB | 平均 87.1 MB | 峰值 87.2 MB
[selftest] 每窗口增量约 5.2 MB（含 WebView）
[selftest] PASS ✅
```

另有设置窗口冒烟测试：

```bash
"./dist/悬浮笔记.app/Contents/MacOS/FloatNotes" --settings-smoke
# [smoke] 设置窗口数量 = 1 尺寸 = {{734, 271}, {460, 652}}
# [smoke] PASS ✅
```

---

## 三、性能量化结果（M1 关键交付）

在 macOS 26.5 / arm64 上实测：

| 指标 | 数值 |
|---|---|
| 基线内存（App 启动，0 个笔记窗口） | **60.8 MB** |
| 5 个笔记窗口时的常驻内存 | **87.2 MB** |
| **每增加一个笔记窗口** | **约 +5.2 MB** |
| 单窗口冷启动到编辑器可用 | < 1 秒 |
| 安装体积 | **3.1 MB**（可执行文件 472 KB） |

**结论：内存表现完全可接受。** 每窗口 5.2 MB 意味着即使同时开 10 个笔记窗口也才 ~113 MB，远低于同类的 Electron/Flutter 方案（通常 300–500 MB 起步）。

> 对比：M0 时每窗口约 4.3–5.6 MB，波动来自采样时机，量级一致。

---

## 四、M1 过程中踩到的两个坑（已解决，记录备查）

### 坑 1 · `callAsyncJavaScript` 拿不到返回值

WKWebView 的 `callAsyncJavaScript` 标了 `NS_REFINED_FOR_SWIFT`，Swift 侧**只有 async 版本，没有 completionHandler 版本**。但直接用 `try await webView.callAsyncJavaScript(...)` 在本机 SDK（macOS 26.5 / CLT 26.5）上**连同步返回值都拿不到，一律返回 `()`**。

**绕过方案**：异步任务在 JS 里把结果写进全局变量，Swift 用可靠的 `evaluateJavaScript` 轮询读取（`window.__fnProbe`）。图片链路测试就是这么做的。

### 坑 2 · 自定义 scheme 下 `fetch()` 被 CORS 挡

`floatnotes://editor/...` 和 `floatnotes://media/...` 虽然同 scheme，但 host 不同 → 属于跨 origin，JS 里 `fetch()` 会报 `TypeError: Load failed`。

**处理**：
1. 响应头补 `Access-Control-Allow-Origin: *`；
2. 更重要的是——**改用真实 `<img>` 加载来做验证**，因为这本来就是编辑器显示图片走的路径，比 `fetch` 更贴近真实场景。

---

## 五、当前可用产物

```
floatnotes/
├── Package.swift                    SPM 清单（macOS 14+）
├── Info.plist                       LSUIElement=true
├── build.sh                         一键构建（无需 Xcode，约 40 秒）
├── Sources/FloatNotes/              1971 行 Swift，11 个文件
│   ├── main.swift                   入口
│   ├── AppDelegate.swift            菜单栏 / 悬浮球 / 热键 / 自检（585 行）
│   ├── NotePanel.swift              置顶面板 + 悬浮球 + 贴边吸附
│   ├── NoteWindowManager.swift      多窗口 / 会话 / 层级 / 收起
│   ├── NoteStore.swift              Markdown 落盘 + 附件 + 会话
│   ├── WebEditorView.swift          WKWebView + JS 桥 + 图片上传
│   ├── EditorSchemeHandler.swift    floatnotes:// 自定义 scheme
│   ├── Settings.swift               设置模型 + 开机自启
│   ├── SettingsWindow.swift         SwiftUI 设置面板
│   ├── HotKey.swift                 Carbon 全局热键
│   └── Perf.swift                   内存量化
└── editor-src/                      BlockNote 编辑器（218 行 JSX）
    ├── vite.config.js               单文件打包
    ├── index.html
    └── src/main.jsx                 zh 中文化 + 图片上传 + 字号
```

---

## 六、快捷键总表

| 快捷键 | 功能 |
|---|---|
| `⌥⌘N` | 新建笔记窗口 |
| `⌥⌘H` | 显示 / 隐藏全部笔记 |
| `⌥⌘R` | 全部收起 / 展开 |
| `⌥⌘L` | 切换「盖住菜单栏和程序坞」 |
| 双击悬浮球 | 直接新建笔记 |
| 右键悬浮球 | 弹出启动菜单 |

---

## 七、仍需人工确认的事项

自动化能验的都验了，剩下这两条必须真人用手感判断：

| # | 事项 | 怎么试 |
|---|---|---|
| 1 | **中文输入法候选框位置** | 切中文输入法，在笔记窗口里打字，看候选词框是否跟得准 |
| 2 | **真实浏览器场景下的焦点** | 浏览器在前台，点笔记窗口打字，看浏览器标题栏有没有变灰 |

---

## 八、已知限制

| # | 限制 | 说明 |
|---|---|---|
| L-1 | Markdown 首次保存会规范化列表符号 | `- ` → `* `，一次性、之后幂等。若要保留原样需改 JSON 真源 |
| L-2 | 开机自启需要 App 在 `/Applications` 下且正式签名 | 当前在 `dist/`，会提示"不可用"，属预期 |
| L-3 | 附件不会被自动回收 | 删掉笔记里的图片后，附件文件仍留在 `attachments/` |
| L-4 | App 未公证 | 自用无影响，分发才需要开发者账号 |
| L-5 | 表格在极窄窗口下需横向滚动 | 已加 `overflow-x: auto`，不会撑破布局 |

---

## 九、下一步（M2 候选）

按价值排序：

1. **划词新建** —— 选中网页文字 → 热键 → 自动新建笔记并带上来源 URL（**对你"读文章记笔记"的场景价值最高**）
2. **外部编辑器实时同步** —— `FSEvents` 监听，Obsidian 改了这边同步
3. **全局搜索 ⌘K** —— 跨所有笔记搜内容
4. **附件回收** —— 清理笔记里已删除图片对应的附件
5. **每窗口独立透明度 / 主题** —— 抄 chirami
6. **导出为 RTF / 复制为富文本**
