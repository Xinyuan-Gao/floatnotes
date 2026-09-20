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
// ── 文字颜色 / 高亮 ──────────────────────────────────────────
//
// Markdown 本身表达不了颜色，BlockNote 的 markdown 导出也会把颜色丢掉
// （实测：设完 textColor 再 blocksToMarkdownLossy，输出里一点颜色信息都没有；
//  同样的内容 blocksToHTMLLossy 是留得住的）。所以走业界通行做法——
// 把带色的文字写成**内联 HTML**：
//
//   <span style="color:#e03131">重要</span>
//   <span style="background-color:#ffec99">划重点</span>
//
// GitHub、Obsidian、VS Code 的 markdown 预览都认这个写法，
// 笔记发给别人、换台机器打开也不会掉色。
//
// 实现上不去动 BlockNote 的序列化器（改不动，而且容易把结构搞坏），
// 而是导出前把带色片段换成占位符、导出后把占位符换回 HTML 标签。
// 结构仍然交给 BlockNote，我们只负责把颜色搬过去。

const TEXT_COLORS = [
  ["default", "默认"], ["red", "红"], ["orange", "橙"], ["yellow", "黄"],
  ["green", "绿"], ["blue", "蓝"], ["purple", "紫"], ["pink", "粉"], ["gray", "灰"],
];
const HIGHLIGHT_COLORS = [
  ["default", "无"], ["red", "红"], ["orange", "橙"], ["yellow", "黄"],
  ["green", "绿"], ["blue", "蓝"], ["purple", "紫"], ["pink", "粉"], ["gray", "灰"],
];

// BlockNote 的颜色是「名字」，别的编辑器只认具体色值，这里做一层映射。
// 用的是它自己那套配色，肉眼观感一致。
const COLOR_HEX = {
  red: "#e03131", orange: "#f08c00", yellow: "#f2c037", green: "#2f9e44",
  blue: "#1971c2", purple: "#9c36b5", pink: "#e64980", gray: "#868e96",
};
const HIGHLIGHT_HEX = {
  red: "#ffc9c9", orange: "#ffd8a8", yellow: "#ffec99", green: "#b2f2bb",
  blue: "#a5d8ff", purple: "#eebefa", pink: "#fcc2d7", gray: "#e9ecef",
};

const TOKEN_RE = /FNCOLORTOKEN(\d+)Z/g;
// 判断用：不能带 /g，否则 test() 会移动 lastIndex，下一次就漏判
const TOKEN_TEST = /FNCOLORTOKEN\d+Z/;

function hexToName(hex, table) {
  if (!hex) return null;
  const h = String(hex).trim().toLowerCase();
  for (const [name, value] of Object.entries(table)) {
    if (value.toLowerCase() === h) return name;
  }
  // 认不出的色值：BlockNote 只接受它自己那几个名字，只能退回默认
  log("颜色 " + hex + " 不在支持列表里，已忽略");
  return null;
}

function escapeHtml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/// 导出前：把带色文字换成占位符，返回 [副本, 记录表]
function withColorTokens(doc) {
  const store = [];
  const clone = JSON.parse(JSON.stringify(doc));
  const walk = (blocks) => {
    for (const b of blocks || []) {
      if (Array.isArray(b.content)) {
        for (const ic of b.content) {
          if (ic.type !== "text" || !ic.styles) continue;
          const tc = ic.styles.textColor && ic.styles.textColor !== "default"
            ? ic.styles.textColor : null;
          const bg = ic.styles.backgroundColor && ic.styles.backgroundColor !== "default"
            ? ic.styles.backgroundColor : null;
          if (!tc && !bg) continue;
          store.push({ text: ic.text, textColor: tc, backgroundColor: bg });
          // 只摘掉颜色，粗体/斜体这些还要留给 BlockNote 去序列化
          delete ic.styles.textColor;
          delete ic.styles.backgroundColor;
          ic.text = "FNCOLORTOKEN" + (store.length - 1) + "Z";
        }
      }
      walk(b.children);
    }
  };
  walk(clone);
  return [clone, store];
}

/// 导出后：把占位符换成内联 HTML
function expandColorTokens(md, store) {
  return md.replace(TOKEN_RE, (_, n) => {
    const e = store[Number(n)];
    if (!e) return "";
    const css = [];
    if (e.textColor) css.push("color:" + (COLOR_HEX[e.textColor] || e.textColor));
    if (e.backgroundColor) {
      css.push("background-color:" + (HIGHLIGHT_HEX[e.backgroundColor] || e.backgroundColor));
    }
    // 不嵌套两层标签：一个 span 同时带前景和背景，导入时正则也好解析
    return '<span style="' + css.join(";") + '">' + escapeHtml(e.text) + "</span>";
  });
}

/// 导入前：把内联 HTML 换回占位符
function extractColorTokens(md) {
  const store = [];
  const out = String(md).replace(
    /<span style="([^"]*)">([\s\S]*?)<\/span>/g,
    (whole, css, text) => {
      const fg = /(?:^|;)\s*color:\s*([^;]+)/.exec(css)?.[1];
      const bg = /background-color:\s*([^;]+)/.exec(css)?.[1];
      const textColor = hexToName(fg, COLOR_HEX);
      const backgroundColor = hexToName(bg, HIGHLIGHT_HEX);
      if (!textColor && !backgroundColor) return text;   // 认不出就只留文字
      store.push({ text, textColor, backgroundColor });
      return "FNCOLORTOKEN" + (store.length - 1) + "Z";
    }
  );
  return [out, store];
}

/// 载入之后：把正文里的占位符拆成「真文字 + 颜色样式」
function splitTokenContent(content, store) {
  const out = [];
  for (const ic of content || []) {
    if (ic.type !== "text" || !ic.text || !TOKEN_TEST.test(ic.text)) {
      out.push(ic);
      continue;
    }
    TOKEN_RE.lastIndex = 0;
    let last = 0, m;
    while ((m = TOKEN_RE.exec(ic.text))) {
      if (m.index > last) {
        out.push({ type: "text", text: ic.text.slice(last, m.index), styles: { ...ic.styles } });
      }
      const e = store[Number(m[1])];
      const styles = { ...ic.styles };
      if (e?.textColor) styles.textColor = e.textColor;
      if (e?.backgroundColor) styles.backgroundColor = e.backgroundColor;
      out.push({ type: "text", text: e ? e.text : "", styles });
      last = m.index + m[0].length;
    }
    if (last < ic.text.length) {
      out.push({ type: "text", text: ic.text.slice(last), styles: { ...ic.styles } });
    }
  }
  return out;
}

/// 载入之后：把含占位符的块改写成「真文字 + 颜色样式」。
/// 必须整块换 content，而不是改文字 —— 占位符会被拆成多段，
/// 每段的样式（粗体等）要继承原来的，颜色只加在对应的那一段上。
function applyColorTokens(editor, store) {
  const fix = (blocks) => {
    for (const b of blocks || []) {
      if (Array.isArray(b.content) &&
          b.content.some((ic) => ic.type === "text" && ic.text && TOKEN_TEST.test(ic.text))) {
        editor.updateBlock(b.id, { content: splitTokenContent(b.content, store) });
      }
      fix(b.children);
    }
  };
  fix(editor.document);
}

// ── 格式工具栏 ───────────────────────────────────────────────//
// 自带一个，而不是用 BlockNote 默认的那个：实测默认工具栏在选中文字时
// **根本没有出现在 DOM 里**（toolbarFound=false），用户因此完全没地方选颜色。
// 自己画还有一个好处：块类型和颜色能放在同一处，不用去翻斜杠菜单。

const BLOCK_KINDS = [
  ["paragraph", "正文"],
  ["heading", "标题 1", { level: 1 }],
  ["heading", "标题 2", { level: 2 }],
  ["heading", "标题 3", { level: 3 }],
  ["quote", "引用"],
  ["codeBlock", "代码块"],
];

// 代码块语言。markdown 的 ```json 围栏本来就带语言，是原生支持的。
const CODE_LANGS = ["text", "json", "markdown", "javascript", "typescript",
                    "python", "bash", "sql", "yaml", "xml", "css", "go", "rust", "java"];

function FnFormatToolbar({ editor }) {
  const [pos, setPos] = useState(null);
  const [active, setActive] = useState({});

  useEffect(() => {
    const update = () => {
      const sel = window.getSelection();
      const root = document.querySelector(".bn-editor");
      if (!sel || sel.isCollapsed || !sel.rangeCount || !root) {
        setPos(null);
        return;
      }
      const range = sel.getRangeAt(0);
      if (!root.contains(range.commonAncestorContainer)) {
        setPos(null);
        return;
      }
      const r = range.getBoundingClientRect();
      if (!r.width && !r.height) {
        setPos(null);
        return;
      }
      // 笔记窗口很小，工具栏默认浮在选区上方 ——
      // 选区靠上时会顶出可视区，那时改成挂在下方；左右也要夹回窗口内
      const below = r.top < 140;
      const half = 210;
      const x = Math.min(Math.max(r.left + r.width / 2, half), window.innerWidth - half);
      setPos({ x, y: below ? r.bottom : r.top, below });
      try {
        setActive(editor.getActiveStyles() || {});
      } catch (e) {
        setActive({});
      }
    };
    document.addEventListener("selectionchange", update);
    return () => document.removeEventListener("selectionchange", update);
  }, [editor]);

  if (!pos) return null;

  // 按住不放会清掉选区，工具栏就没了 —— preventDefault 保住选中状态
  const hold = (fn) => (e) => {
    e.preventDefault();
    e.stopPropagation();
    fn();
  };
  const style = (s) => hold(() => editor.toggleStyles({ [s]: true }));
  const setColor = (key, value) => hold(() => editor.addStyles({ [key]: value }));
  const setBlock = (kind, props) => hold(() => {
    const b = editor.getTextCursorPosition?.()?.block;
    if (b) editor.updateBlock(b, { type: kind, props: { ...(props || {}) } });
  });

  const Btn = ({ on, label, title }) => (
    <button
      className={"fn-tb-btn" + (on ? " on" : "")}
      onMouseDown={on === undefined ? undefined : undefined}
      onClick={on}
      title={title || label}
    >{label}</button>
  );

  return (
    <div className={"fn-toolbar" + (pos.below ? " below" : "")}
         style={{ left: pos.x, top: pos.y }}
         onMouseDown={(e) => e.preventDefault()}>
      <div className="fn-tb-row">
        <Btn on={style("bold")} label="B" title="粗体" />
        <Btn on={style("italic")} label="I" title="斜体" />
        <Btn on={style("underline")} label="U" title="下划线" />
        <Btn on={style("strike")} label="S" title="删除线" />
        <Btn on={style("code")} label="&lt;/&gt;" title="行内代码" />
        <span className="fn-tb-sep" />
        {BLOCK_KINDS.map(([kind, label, props]) => (
          <button key={label} className="fn-tb-btn fn-tb-wide"
                  onClick={setBlock(kind, props)} title={"转为" + label}>{label}</button>
        ))}
      </div>
      <div className="fn-tb-row">
        <span className="fn-tb-label">字色</span>
        {TEXT_COLORS.map(([name, label]) => (
          <button key={"fg" + name} className="fn-tb-swatch" title={"文字" + label}
                  style={{ background: COLOR_HEX[name] || "transparent" }}
                  onClick={setColor("textColor", name)} />
        ))}
        <span className="fn-tb-sep" />
        <span className="fn-tb-label">高亮</span>
        {HIGHLIGHT_COLORS.map(([name, label]) => (
          <button key={"bg" + name} className="fn-tb-swatch" title={"高亮" + label}
                  style={{ background: HIGHLIGHT_HEX[name] || "transparent" }}
                  onClick={setColor("backgroundColor", name)} />
        ))}
      </div>
      <div className="fn-tb-row">
        <span className="fn-tb-label">代码语言</span>
        {CODE_LANGS.map((l) => (
          <button key={l} className="fn-tb-btn" title={"代码块语言 " + l}
                  onClick={hold(() => {
                    const b = editor.getTextCursorPosition?.()?.block;
                    if (b) editor.updateBlock(b, { type: "codeBlock", props: { language: l } });
                  })}>{l}</button>
        ))}
      </div>
    </div>
  );
}

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
          // 先把内联 HTML 颜色换成占位符，让 BlockNote 正常解析结构；
          // 载入完成后再把占位符拆回「真文字 + 颜色样式」
          const [withTokens, store] = extractColorTokens(markdown);
          const blocks = await editor.tryParseMarkdownToBlocks(withTokens);
          if (blocks?.length) {
            editor.replaceBlocks(editor.document, blocks);
            if (store.length) applyColorTokens(editor, store);
            log("已载入 " + blocks.length + " 个块"
                + (store.length ? "（含 " + store.length + " 处颜色）" : ""));
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
            // 先把带色片段换成占位符再交给 BlockNote 序列化，
            // 拿回来再把占位符展开成内联 HTML —— 这样颜色才进得了 .md
            const [doc, store] = withColorTokens(editor.document);
            const raw = await editor.blocksToMarkdownLossy(doc);
            window.__fnMd = { done: true, value: expandColorTokens(raw || "", store) };
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

      // 自检用：把编辑器的「能力清单」原样报出来 ——
      // 有哪些块类型、哪些内联样式、格式工具栏上实际有哪些按钮、
      // 以及设了文字颜色之后 markdown 里还留不留得住。
      // 光读 BlockNote 的类型定义没用，得看真实 DOM 和真实导出结果。
      async _editorProbe() {
        const out = {};
        const wait = (ms) => new Promise((r) => setTimeout(r, ms));
        try {
          out.blockTypes = Object.keys(editor.schema.blockSpecs || {});
          out.styleSpecs = Object.keys(editor.schema.styleSpecs || {});
          const cb = editor.schema.blockSpecs?.codeBlock;
          out.codeBlockLanguageValues =
            cb?.config?.propSchema?.language?.values ?? null;

          // 选中一段真实文字，看格式工具栏冒出来什么
          const pm = editor._tiptapEditor || editor.prosemirrorEditor;
          let from = null, to = null;
          pm.state.doc.descendants((node, pos) => {
            if (from === null && node.isText && node.text.trim().length > 3) {
              from = pos;
              to = pos + Math.min(6, node.text.length);
            }
            return true;
          });
          out.selectionMade = from !== null;
          if (from !== null) {
            pm.commands.setTextSelection({ from, to });
            await wait(500);
            // 自带工具栏（实测不出现，记下来做对比）
            out.bnToolbarFound = !!(
              document.querySelector(".bn-formatting-toolbar") ||
              document.querySelector('[class*="formatting-toolbar"]')
            );
            // 我们自己的工具栏：选中之后应该出现
            let mine = document.querySelector(".fn-toolbar");
            out.ourToolbarShownOnSelection = !!mine;
            out.ourToolbarButtons = mine ? mine.querySelectorAll("button").length : 0;

            // 工具栏要用到的 API 在 0.39 里是否真的存在
            out.api = {
              addStyles: typeof editor.addStyles,
              toggleStyles: typeof editor.toggleStyles,
              getActiveStyles: typeof editor.getActiveStyles,
              getTextCursorPosition: typeof editor.getTextCursorPosition,
              updateBlock: typeof editor.updateBlock,
            };

            // 用 DOM Range 再选一次 —— 真人拖选就是这个路径，
            // 上面 PM 命令不一定触发 selectionchange
            try {
              const textNode = document.querySelector(".bn-editor [data-content-type] .bn-inline-content")
                ?.firstChild;
              if (textNode && textNode.nodeType === 3) {
                const r = document.createRange();
                r.setStart(textNode, 0);
                r.setEnd(textNode, Math.min(4, textNode.length));
                const ds = window.getSelection();
                ds.removeAllRanges();
                ds.addRange(r);
                document.dispatchEvent(new Event("selectionchange"));
                await wait(300);
                mine = document.querySelector(".fn-toolbar");
                out.ourToolbarShownOnDomSelection = !!mine;
                out.ourToolbarButtons = mine ? mine.querySelectorAll("button").length : 0;

                // 真的点一下色块，看颜色有没有落到文档上 ——
                // 光看工具栏出现还不够，按钮接没接对才是关键
                const swatches = mine ? [...mine.querySelectorAll(".fn-tb-swatch")] : [];
                out.swatchCount = swatches.length;
                if (swatches.length > 1) {
                  swatches[1].dispatchEvent(new MouseEvent("click", { bubbles: true }));
                  await wait(400);
                  out.clickRedApplied = JSON.stringify(editor.document).includes('"textColor":"red"');
                }
                // 再点一下「高亮」那一排的第一个色块
                if (swatches.length > 9) {
                  const before = JSON.stringify(editor.document);
                  swatches[9].dispatchEvent(new MouseEvent("click", { bubbles: true }));
                  await wait(400);
                  out.clickHighlightChanged = JSON.stringify(editor.document) !== before;
                }
              }
            } catch (e) {
              out.domSelectionError = String(e);
            }
          }

          // 颜色进出 md 的完整往返：设色 → 导出 → 看 md 里有没有 → 再载回来 → 看还在不在
          try {
            const first = editor.document.find(
              (b) => Array.isArray(b.content) && b.content.some((c) => c.type === "text")
            );
            const ic = first.content.find((c) => c.type === "text" && c.text.trim());
            const half = Math.max(1, Math.floor(ic.text.length / 2));
            const content = first.content.map((c) => {
              if (c !== ic) return c;
              return [
                { type: "text", text: c.text.slice(0, half), styles: { ...c.styles } },
                { type: "text", text: c.text.slice(half), styles: { ...c.styles, textColor: "red", backgroundColor: "yellow" } },
              ];
            }).flat();
            editor.updateBlock(first.id, { content });
            await wait(300);

            const [doc, store] = withColorTokens(editor.document);
            const raw = await editor.blocksToMarkdownLossy(doc);
            const md = expandColorTokens(raw, store);
            out.colorRoundTripTokenCount = store.length;
            out.mdHasColorHtml = /<span style="color:#e03131/.test(md);
            out.mdColorSample = (md.match(/<span[^>]*>[^<]*<\/span>/) || [""])[0];

            // 再走一遍导入
            const [back, store2] = extractColorTokens(md);
            out.reimportTokenCount = store2.length;
            const blocks = await editor.tryParseMarkdownToBlocks(back);
            editor.replaceBlocks(editor.document, blocks);
            if (store2.length) applyColorTokens(editor, store2);
            await wait(300);
            const hasRed = JSON.stringify(editor.document).includes('"textColor":"red"');
            const hasYellow = JSON.stringify(editor.document).includes('"backgroundColor":"yellow"');
            out.reimportRestoredColor = hasRed;
            out.reimportRestoredHighlight = hasYellow;
          } catch (e) {
            out.colorRoundTripError = String(e);
          }

          // 代码块语言能不能设上、md 围栏里带不带
          try {
            const b = editor.document[editor.document.length - 1];
            editor.updateBlock(b.id, { type: "codeBlock", props: { language: "json" } });
            await wait(250);
            const [d2, s2] = withColorTokens(editor.document);
            const md2 = expandColorTokens(await editor.blocksToMarkdownLossy(d2), s2);
            out.codeFence = (md2.match(/```[a-zA-Z]*/) || [""])[0];
            out.codeLangSet = JSON.stringify(editor.document).includes('"language":"json"');
          } catch (e) {
            out.codeLangError = String(e);
          }
        } catch (e) {
          out.error = String(e);
        }
        // 异步结果只能靠全局变量传出去 ——
        // 这个 SDK 里 callAsyncJavaScript 是坏的（返回空），只能 evaluateJavaScript + 轮询
        window.__fnEditorProbe = JSON.stringify(out);
        return window.__fnEditorProbe;
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
      <FnFormatToolbar editor={editor} />
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
