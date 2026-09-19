import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { useCreateBlockNote } from "@blocknote/react";
import { BlockNoteView } from "@blocknote/mantine";
import { zh } from "@blocknote/core/locales";

import "@blocknote/core/fonts/inter.css";
import "@blocknote/mantine/style.css";

// ── Swift 桥 ────────────────────────────────────────────────
const post = (msg) => {
  try {
    window.webkit?.messageHandlers?.floatnotes?.postMessage(msg);
  } catch (e) {
    /* 在普通浏览器里打开时忽略 */
  }
};
const log = (text) => post({ type: "log", text });

// 判断某个元素是不是「编辑区的空白处」：
// 在编辑区之内、但不在任何内容块（.bn-block-content）里。
// 左右内边距、正文下方的空区都命中编辑器根元素，正好落在这个定义里。
function isBlankTarget(el) {
  if (!el || typeof el.closest !== "function") return false;
  if (!el.closest(".bn-container")) return false;      // 不在编辑区
  if (el.closest(".bn-block-content")) return false;   // 落在某个块上
  return true;
}

const prefersDark = () =>
  window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;

// ── 图片上传（粘贴 / 拖入 / 选择）──────────────────────────
// 图片不在浏览器里存 base64，而是交给 Swift 落盘到附件目录，
// 回传文件名后拼成 floatnotes://media/<名>，由自定义 scheme 提供。
const pendingUploads = new Map();
let uploadSeq = 0;

function requestUpload(file) {
  return new Promise((resolve) => {
    const id = "u" + ++uploadSeq;
    const cleanup = () => pendingUploads.delete(id);

    const timer = setTimeout(() => {
      if (pendingUploads.has(id)) {
        cleanup();
        log("附件上传超时：" + (file.name || "未命名"));
        resolve(null);
      }
    }, 20000);

    pendingUploads.set(id, (filename) => {
      clearTimeout(timer);
      cleanup();
      resolve(filename);
    });

    const reader = new FileReader();
    reader.onload = () => {
      const s = String(reader.result || "");
      const comma = s.indexOf(",");
      post({
        type: "upload",
        id,
        name: file.name || "paste.png",
        mime: file.type || "image/png",
        data: comma >= 0 ? s.slice(comma + 1) : s,
      });
    };
    reader.onerror = () => {
      clearTimeout(timer);
      cleanup();
      log("附件读取失败：" + (file.name || "未命名"));
      resolve(null);
    };
    reader.readAsDataURL(file);
  });
}

// ── 编辑器 ─────────────────────────────────────────────────
function App() {
  const [systemDark, setSystemDark] = useState(prefersDark);
  // "auto" | "light" | "dark" —— Swift 可以通过 window.FloatNotes.setTheme() 覆盖
  const [themeMode, setThemeMode] = useState("auto");
  const dark = themeMode === "auto" ? systemDark : themeMode === "dark";
  const rootRef = useRef(null);

  const editor = useCreateBlockNote({
    dictionary: zh,
    uploadFile: async (file) => {
      const name = await requestUpload(file);
      if (!name) throw new Error("图片保存失败");
      return `floatnotes://media/${name}`;
    },
  });

  const emitChange = useCallback(async () => {
    try {
      const md = await editor.blocksToMarkdownLossy(editor.document);
      // 诊断用：真实打字到底有没有触发 onChange。
      // 「字进不去编辑器」和「进了但回调没触发」是两种完全不同的故障，
      // 没有这个计数器就只能靠猜。
      window.__fnChangeCount = (window.__fnChangeCount || 0) + 1;
      post({ type: "change", markdown: md });
    } catch (e) {
      log("Markdown 导出失败: " + e);
    }
  }, [editor]);

  // 暴露给 Swift 调用的 API
  useEffect(() => {
    window.FloatNotes = {
      async load(markdown) {
        if (!markdown || !markdown.trim()) return;
        try {
          const blocks = await editor.tryParseMarkdownToBlocks(markdown);
          if (blocks?.length) {
            editor.replaceBlocks(editor.document, blocks);
            log("已载入 " + blocks.length + " 个块");
          }
        } catch (e) {
          log("载入失败: " + e);
        }
      },
      exportNow() {
        emitChange();
      },
      focus() {
        editor.focus();
      },
      setEditable(v) {
        editor.isEditable = !!v;
      },
      setFontSize(px) {
        const n = Number(px);
        if (Number.isFinite(n) && n >= 8 && n <= 48) {
          document.documentElement.style.setProperty("--fn-font-size", n + "px");
        }
      },
      // 笔记背景图。key 是 BackgroundCatalog 里的文件名（不含扩展名），
      // "none" 表示不要背景。isDark 决定用深护罩还是浅护罩。
      setBackground(key, isDark) {
        const body = document.body;
        if (!key || key === "none") {
          body.classList.remove("fn-has-bg", "fn-bg-dark");
          body.style.backgroundImage = "";
          return;
        }
        body.classList.add("fn-has-bg");
        body.classList.toggle("fn-bg-dark", !!isDark);
        const url = "floatnotes://bg/" + key + ".jpg";
        body.style.backgroundImage = 'url("' + url + '")';
        // 报一下加载结果 —— scheme 没配对的话这里会立刻暴露
        const probe = new Image();
        probe.onload = () => log("背景已加载：" + key + " " + probe.naturalWidth + "×" + probe.naturalHeight);
        probe.onerror = () => log("背景加载失败：" + key + "（" + url + "）");
        probe.src = url;

        // ★ 背景反过来决定主题。
        //   浅底必须配浅色主题（深字），深底必须配深色主题（浅字）——
        //   否则会出现「深字压深底」这种完全看不清的组合。
        //   所以只要选了背景，就由背景说了算，忽略单独的主题设置。
        window.dispatchEvent(
          new CustomEvent("fn-theme", { detail: isDark ? "dark" : "light" })
        );
        log("背景主题：跟随背景 → " + (isDark ? "深色" : "浅色"));
      },

      // 正文字体（CSS font-family 字符串）
      setFontFamily(css) {
        if (typeof css === "string" && css.trim()) {
          document.documentElement.style.setProperty("--fn-font-family", css);
        }
      },
      // 追加一段 Markdown 到文档末尾（今日笔记用）
      _startAppend(md) {
        window.__fnAppend = { done: false, ok: false };
        (async () => {
          try {
            const blocks = await editor.tryParseMarkdownToBlocks(md);
            if (!blocks || !blocks.length) {
              window.__fnAppend = { done: true, ok: false };
              return;
            }
            const doc = editor.document;
            const last = doc[doc.length - 1];
            if (last) {
              editor.insertBlocks(blocks, last, "after");
            } else {
              editor.replaceBlocks(doc, blocks);
            }
            window.__fnAppend = { done: true, ok: true };
          } catch (e) {
            log("追加失败: " + e);
            window.__fnAppend = { done: true, ok: false };
          }
        })();
        return "started";
      },
      setTheme(mode) {
        window.dispatchEvent(
          new CustomEvent("fn-theme", {
            detail: ["auto", "light", "dark"].includes(mode) ? mode : "auto",
          })
        );
      },
      // 导出用：把当前文档转成 HTML，结果写进全局变量供 Swift 轮询。
      // 注意 blocksToHTMLLossy 是「同步」返回字符串的（不像 markdown 那两个是 async），
      // 所以这里用 async IIFE 包一层，避免直接 .then 报 "not a function"。
      _startHTMLExport() {
        window.__fnHtml = { done: false, value: null };
        (async () => {
          try {
            const v = await editor.blocksToHTMLLossy(editor.document);
            window.__fnHtml = { done: true, value: v || "" };
          } catch (e) {
            log("HTML 导出失败: " + e);
            window.__fnHtml = { done: true, value: null };
          }
        })();
        return "started";
      },
      // Swift 回传附件保存结果
      _uploadResult(id, filename) {
        const fn = pendingUploads.get(id);
        if (fn) fn(filename);
      },
      // 自检用：导出真正的 markdown（落盘用的就是它）
      _startMarkdownExport() {
        window.__fnMd = { done: false, value: null };
        (async () => {
          try {
            const v = await editor.blocksToMarkdownLossy(editor.document);
            window.__fnMd = { done: true, value: v || "" };
          } catch (e) {
            window.__fnMd = { done: true, value: "ERR " + e };
          }
        })();
        return "started";
      },

      // 自检用：插入一个图片块
      _insertImage(url, caption) {
        const block = { type: "image", props: { url, caption: caption || "" } };
        let ref = null;
        try { ref = editor.getTextCursorPosition().block; } catch (e) { ref = null; }
        if (!ref) ref = editor.document[editor.document.length - 1];
        if (ref) editor.insertBlocks([block], ref, "after");
        else editor.replaceBlocks(editor.document, [block]);
        return "inserted";
      },

      // 自检用：滚动相关度量
      _scrollInfo() {
        const pick = (sel) => {
          const el = document.querySelector(sel);
          if (!el) return null;
          const cs = getComputedStyle(el);
          return {
            sel,
            overflowY: cs.overflowY,
            scrollH: el.scrollHeight,
            clientH: el.clientHeight,
            canScroll: el.scrollHeight > el.clientHeight + 2,
          };
        };
        return JSON.stringify({
          html: pick("html"),
          body: pick("body"),
          container: pick(".bn-container"),
          editor: pick(".bn-editor"),
          viewportH: window.innerHeight,
        });
      },

      // 自检用：真的滚一下，返回滚动前后的 scrollTop
      _tryScroll(delta) {
        const cands = [".bn-container", ".bn-editor", "body", "html"];
        for (const sel of cands) {
          const el = document.querySelector(sel);
          if (!el) continue;
          const before = el.scrollTop;
          el.scrollTop = before + delta;
          if (el.scrollTop !== before) {
            return JSON.stringify({ ok: true, sel, before, after: el.scrollTop });
          }
        }
        return JSON.stringify({ ok: false, reason: "没有元素能滚动" });
      },

      // 自检用：验证背景图能不能经 floatnotes://bg/ 取到
      _startBgProbe(key) {
        window.__fnBg = { done: false, ok: false, w: 0, h: 0 };
        const img = new Image();
        img.onload = () => {
          window.__fnBg = { done: true, ok: true, w: img.naturalWidth, h: img.naturalHeight };
        };
        img.onerror = () => { window.__fnBg = { done: true, ok: false, w: 0, h: 0 }; };
        img.src = "floatnotes://bg/" + key + ".jpg";
        return "started";
      },
      // 自检用：当前背景状态
      _bgState() {
        const cs = getComputedStyle(document.body);
        return JSON.stringify({
          hasClass: document.body.classList.contains("fn-has-bg"),
          isDark: document.body.classList.contains("fn-bg-dark"),
          bg: cs.backgroundImage.slice(0, 80),
        });
      },
      // 自检用：某个坐标点算不算空白
      _testBlankAt(x, y) {
        return isBlankTarget(document.elementFromPoint(x, y));
      },
      // 自检用
      async status() {
        const md = await editor.blocksToMarkdownLossy(editor.document);
        return { blocks: editor.document.length, markdownLength: md.length };
      },

      // 自检：跑一遍图片粘贴的完整链路
      // 构造 File → 交给 Swift 落盘 → 再用 floatnotes:// 取回来，验证 scheme 真的能供图
      async _testImage(b64, mime) {
        try {
          const bin = atob(b64);
          const arr = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
          const file = new File([arr], "selftest.png", { type: mime || "image/png" });

          const name = await requestUpload(file);
          if (!name) return JSON.stringify({ ok: false, reason: "Swift 未回传文件名" });

          const url = `floatnotes://media/${name}`;

          // 用真实 <img> 加载来验证 —— 这才是编辑器显示图片时走的路径
          const img = new Image();
          const loaded = await new Promise((resolve) => {
            const t = setTimeout(() => resolve(false), 8000);
            img.onload = () => { clearTimeout(t); resolve(true); };
            img.onerror = () => { clearTimeout(t); resolve(false); };
            img.src = url;
          });

          return JSON.stringify({
            ok: loaded && img.naturalWidth > 0,
            filename: name,
            width: img.naturalWidth,
            height: img.naturalHeight,
            src: url,
          });
        } catch (e) {
          return JSON.stringify({ ok: false, reason: String(e) });
        }
      },

      // 启动图片自检并把结果写进全局变量，供 Swift 轮询读取。
      // （不用 Promise 回传是因为 WKWebView 的 callAsyncJavaScript 在本机 SDK 上
      //   拿不到返回值，而 evaluateJavaScript 是可靠的。）
      _startImageTest(b64, mime) {
        window.__fnProbe = { done: false, value: null };
        this._testImage(b64, mime)
          .then((v) => { window.__fnProbe = { done: true, value: v }; })
          .catch((e) => {
            window.__fnProbe = {
              done: true,
              value: JSON.stringify({ ok: false, reason: String(e) }),
            };
          });
        return "started";
      },
    };
    log("BlockNote 已初始化，块数=" + editor.document.length);
    post({ type: "ready" });
  }, [editor, emitChange]);

  // 跟随系统深浅色
  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const onChange = (e) => setSystemDark(e.matches);
    mq.addEventListener?.("change", onChange);
    return () => mq.removeEventListener?.("change", onChange);
  }, []);

  // 告诉 Swift 指针现在是不是停在空白处 —— 决定「按住空白拖动窗口」能不能触发。
  // 只在状态翻转时发消息，避免每次 mousemove 都过一遍桥。
  useEffect(() => {
    let last = null;
    const report = (blank) => {
      if (blank !== last) { last = blank; post({ type: "blankHover", blank }); }
    };
    const onMove = (e) => report(isBlankTarget(e.target));
    document.addEventListener("mousemove", onMove, true);
    document.addEventListener("mouseleave", () => report(false));
    return () => document.removeEventListener("mousemove", onMove, true);
  }, []);

  // 粘贴图片时显式插成「内嵌图片」块。
  //
  // BlockNote 自带的插入逻辑是按 MIME 逐个块规格匹配，最后一个匹配的赢；
  // 但它的 checkMIMETypesMatch 对 "*/*" 的处理是要求类型段相等，
  // 结果什么都匹配不上，退回默认的 "file" 块 —— 用户看到的是个文件附件，
  // 不是内嵌图片。这里直接接管，保证粘进来就是图。
  useEffect(() => {
    const insertImageBlock = (url) => {
      const block = { type: "image", props: { url } };
      let ref = null;
      try {
        ref = editor.getTextCursorPosition().block;
      } catch (e) {
        ref = null;
      }
      if (!ref) ref = editor.document[editor.document.length - 1];
      if (ref) editor.insertBlocks([block], ref, "after");
      else editor.replaceBlocks(editor.document, [block]);
    };

    const looksLikeImage = (item, file) => {
      const t = (item.type || file?.type || "").toLowerCase();
      if (t.startsWith("image/")) return true;
      return /\.(png|jpe?g|gif|webp|heic|heif|tiff?|bmp)$/i.test(file?.name || "");
    };

    const onPaste = async (e) => {
      const dt = e.clipboardData;
      if (!dt) return;

      const items = Array.from(dt.items || []);
      const target = items.find((it) => {
        if (it.kind !== "file") return false;
        return looksLikeImage(it, it.getAsFile());
      });
      if (!target) return;

      const file = target.getAsFile();
      if (!file) return;

      log("粘贴图片：" + items.map((it) =>
        it.kind + ":" + (it.type || "-") + ":" + (it.getAsFile()?.name || "-")
      ).join(" | "));

      // 抢在 BlockNote 自己的处理之前
      e.preventDefault();
      e.stopPropagation();

      const name = await requestUpload(file);
      if (!name) return;
      insertImageBlock(`floatnotes://media/${name}`);
    };

    // 拖拽图片进来走的是另一条路（drop 而不是 paste），
    // BlockNote 自己那套会建成「文件附件」块。这里一并接管，保持和粘贴一致。
    const onDrop = async (e) => {
      const dt = e.dataTransfer;
      if (!dt) return;
      const files = Array.from(dt.files || []);
      const img = files.find((f) => looksLikeImage({ type: f.type }, f));
      if (!img) return;

      e.preventDefault();
      e.stopPropagation();

      const name = await requestUpload(img);
      if (!name) return;
      insertImageBlock(`floatnotes://media/${name}`);
    };

    document.addEventListener("paste", onPaste, true);
    document.addEventListener("drop", onDrop, true);
    return () => {
      document.removeEventListener("paste", onPaste, true);
      document.removeEventListener("drop", onDrop, true);
    };
  }, [editor]);

  // 主题覆盖
  useEffect(() => {
    const h = (e) => setThemeMode(e.detail || "auto");
    window.addEventListener("fn-theme", h);
    return () => window.removeEventListener("fn-theme", h);
  }, []);

  return (
    <div ref={rootRef} style={{ height: "100%" }}>
      <BlockNoteView
        editor={editor}
        theme={dark ? "dark" : "light"}
        onChange={emitChange}
      />
    </div>
  );
}

// 全局兜底
window.addEventListener("error", (e) => log("运行时错误: " + e.message));
window.addEventListener("unhandledrejection", (e) =>
  log("未处理的 Promise 拒绝: " + (e.reason?.message ?? e.reason))
);

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
