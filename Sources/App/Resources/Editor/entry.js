import {Editor, rootCtx, defaultValueCtx, editorViewCtx, editorViewOptionsCtx, editorStateOptionsCtx} from "@milkdown/kit/core";
import {commonmark, imageSchema, linkSchema} from "@milkdown/kit/preset/commonmark";
import {gfm} from "@milkdown/kit/preset/gfm";
import {history, undo, redo, closeHistory} from "@milkdown/kit/prose/history";
import {keymap} from "@milkdown/kit/prose/keymap";
import {selectAll, baseKeymap} from "@milkdown/kit/prose/commands";
import {EditorState, Plugin} from "@milkdown/kit/prose/state";
import {Decoration, DecorationSet} from "@milkdown/kit/prose/view";
import {rawSchema, rawJSON} from "./raw-schema.js";
import {lineMap, rawPlugin, rawKey, rawSelection, selectionFor, replacement, trackRaw} from "./raw-document.js";
import {neutralCopy} from "./neutral-copy.js";
import {rawPresentation, rawPresentationKey, syntaxRanges} from "./raw-presentation.js";

let editor, view, sessionID, epoch = 0, seq = 0, composing = false, locked = false;
let configuration, source = "", retainedSelection, rawState, compositionFinished;
let nextImageID = 0, focusOnResume = false;
const imageRequests = new Map(), imageURLs = new Map();
const root = document.getElementById("editor");
const toggle = document.getElementById("mode-toggle");
const toolbar = document.getElementById("editor-toolbar");
const formatTools = document.getElementById("format-tools");
const isRaw = () => configuration.mode !== "preview";
// WK 통합 테스트도 실제 PM transaction을 사용할 수 있는 읽기 전용 접근점이다.
Object.defineProperty(window, "markAgentEditorView", {get: () => view});
function emit(type, extra = {}) {
  window.webkit.messageHandlers.markAgentEditor.postMessage({version: 1, sessionID, epoch, seq: ++seq, type, ...extra});
}
function snapshot() {
  if (isRaw()) { source = rawKey.getState(view.state); retainedSelection = rawSelection(view.state); }
  return {text: source, selection: retainedSelection};
}
function theme() {
  const value = configuration.theme ?? {};
  for (const name of ["keyword", "string", "number", "tag"]) {
    root.style.setProperty(`--syntax-${name}`, value[name] ?? "currentColor");
  }
  root.style.color = value.foreground ?? "#222";
  root.style.background = value.background ?? "#fff";
  root.style.colorScheme = value.dark ? "dark" : "light";
  root.style.setProperty("--accent", value.accent ?? "#007aff");
  document.body.style.color = root.style.color;
  document.body.style.background = root.style.background;
  document.body.style.colorScheme = root.style.colorScheme;
  document.body.style.setProperty("--accent", value.accent ?? "#007aff");
  root.dataset.mode = isRaw() ? "raw" : "preview";
  toggle.textContent = isRaw() ? "Preview" : "Edit";
  toggle.hidden = configuration.showsModeToggle !== true;
  if (toolbar) toolbar.hidden = configuration.showsModeToggle !== true;
  if (formatTools) formatTools.hidden = !isRaw();
  if (isRaw()) {
    view.dispatch(view.state.tr.setMeta(rawPresentationKey, {language: configuration.language})
      .setMeta("addToHistory", false));
  }
}
function insertLiteral(text) {
  const current = snapshot(), range = current.selection;
  const raw = current.text.slice(0, range.location) + text + current.text.slice(range.location + range.length);
  view.dispatch(closeHistory(replacement(view.state, raw, {location: range.location + text.length, length: 0})));
  view.dispatch(closeHistory(view.state.tr));
}
function copy(event, cut = false) {
  if (!event.clipboardData) return false;
  if (!isRaw()) {
    const data = neutralCopy(view.dom);
    if (!data) return false;
    event.clipboardData.setData("text/html", data.html);
    event.clipboardData.setData("text/plain", data.text);
  } else {
    const current = snapshot(), range = current.selection;
    if (!range.length) return false;
    event.clipboardData.setData("text/plain", current.text.slice(range.location, range.location + range.length));
    if (cut && !locked) insertLiteral("");
  }
  event.preventDefault();
  return true;
}
function dispatchTransaction(tr) {
  if (tr.docChanged && (locked || !isRaw()) && !tr.getMeta("host")) return;
  if (isRaw()) trackRaw(view.state, tr);
  view.updateState(view.state.apply(tr));
  if (isRaw() && (tr.docChanged || tr.selectionSet) && !tr.getMeta("host")) emit("state", snapshot());
}
async function mount() {
  const raw = isRaw();
  editor = await Editor.make().config(ctx => {
    ctx.set(rootCtx, root);
    ctx.set(defaultValueCtx, raw ? {type: "json", value: rawJSON(lineMap(source).text)} : source);
    if (!raw) ctx.update(imageSchema.key, factory => context => {
      const spec = factory(context);
      return {...spec, parseMarkdown: {...spec.parseMarkdown,
        runner: (state, node, type) => state.addNode(type, {
          src: node.url, alt: node.alt ?? "", title: node.title ?? ""
        })}};
    });
    if (!raw) ctx.update(linkSchema.key, factory => context => {
      const spec = factory(context);
      return {...spec, toDOM: mark => {
        const dom = spec.toDOM(mark);
        if (mark.attrs.href.startsWith("file:")) dom[1].href = mark.attrs.href;
        return dom;
      }};
    });
    if (raw) ctx.set(editorStateOptionsCtx, options => ({...options, plugins: [
      rawPlugin(source), rawPresentation(configuration.language), history(),
      keymap({"Mod-z": undo, "Mod-Shift-z": redo, "Mod-y": redo, "Mod-a": selectAll,
        Enter: () => { if (!locked) insertLiteral(lineMap(source).separators[0] ?? "\n"); return true; },
        Tab: () => { if (!locked) insertLiteral("\t"); return true; }}),
      keymap(baseKeymap), ...options.plugins
    ]}));
    else ctx.set(editorStateOptionsCtx, options => ({...options, plugins: [
      new Plugin({props: {decorations: state => {
        const decorations = [];
        state.doc.descendants((node, position) => {
          if (node.type.name !== "code_block") return;
          for (const range of syntaxRanges(node.textContent, node.attrs.language || "text")) {
            decorations.push(Decoration.inline(position + range.from, position + range.to, {class: range.classes}));
          }
        });
        return DecorationSet.create(state.doc, decorations);
      }}}),
      ...options.plugins
    ]}));
    ctx.set(editorViewOptionsCtx, {
      editable: () => isRaw() && !locked,
      attributes: {"aria-label": raw ? "Edit" : "Preview", tabindex: "0", spellcheck: "false"},
      dispatchTransaction,
      handleDOMEvents: {
        compositionstart() { composing = true; return false; },
        compositionend() {
          composing = false;
          queueMicrotask(() => compositionFinished?.());
          return false;
        },
        copy: (_view, event) => copy(event),
        cut: (_view, event) => {
          if (!isRaw() || locked) { event.preventDefault(); return true; }
          return copy(event, true);
        },
        paste: (_view, event) => {
          if (isRaw() && !locked && event.clipboardData) insertLiteral(event.clipboardData.getData("text/plain"));
          event.preventDefault(); return true;
        },
        drop: (_view, event) => { event.preventDefault(); return true; },
        keydown: (_view, event) => {
          if (!isRaw() && (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
            const selection = window.getSelection(), range = document.createRange();
            range.selectNodeContents(view.dom); selection.removeAllRanges(); selection.addRange(range);
            event.preventDefault(); return true;
          }
          return false;
        }
      }
    });
  }).use(raw ? rawSchema : [commonmark, gfm].flat()).create();
  view = editor.ctx.get(editorViewCtx);
  imageRequests.clear();
  imageURLs.clear();
  if (!raw) {
    let links = view.state.tr;
    view.state.doc.descendants((node, position) => {
      for (const mark of node.marks) {
        if (mark.type.name !== "link" || mark.attrs.href.startsWith("#")) continue;
        const href = new URL(mark.attrs.href, configuration.baseURL || window.location.href).href;
        if (href === mark.attrs.href) continue;
        links = links.removeMark(position, position + node.nodeSize, mark)
          .addMark(position, position + node.nodeSize, mark.type.create({...mark.attrs, href}));
      }
    });
    if (links.docChanged) view.dispatch(links.setMeta("host", true));
    view.state.doc.descendants((node, position) => {
      if (node.type.name !== "image" || !node.attrs.src || /^(data:|https?:)/i.test(node.attrs.src)) return;
      const imageID = ++nextImageID;
      imageRequests.set(imageID, position);
      emit("image", {imageID, source: node.attrs.src});
    });
    view.dom.addEventListener("click", event => {
      const image = event.target.closest("img");
      const link = event.target.closest("a[href]");
      const url = link?.href ?? (image && (imageURLs.get(view.posAtDOM(image, 0)) ??
        (/^https?:/i.test(image.src) ? image.src : null)));
      if (!url || !window.getSelection()?.isCollapsed) return;
      event.preventDefault();
      emit("openLink", {url});
    });
  }
  if (rawState && raw) {
    view.updateState(rawState.reconfigure({plugins: view.state.plugins}));
    rawState = null;
  }
  else if (raw) view.dispatch(view.state.tr.setSelection(selectionFor(view.state.doc, source, retainedSelection)).setMeta("host", true));
  theme();
}
async function settleComposition() {
  if (composing) await new Promise(resolve => { compositionFinished = resolve; });
  compositionFinished = null;
  await Promise.resolve();
  // 고정된 PM DOMObserver의 동기 flush: 비활성 탭에서도 rAF를 기다리지 않는다.
  view.domObserver.forceFlush();
}
toggle.addEventListener("click", () => emit("modeToggle"));
formatTools?.addEventListener("mousedown", event => event.preventDefault());
formatTools?.addEventListener("click", event => {
  const action = event.target.closest("button[data-format]")?.dataset.format;
  if (action && isRaw() && !locked) emit("format", {action});
});
// 읽기 전용 WK의 메뉴 Copy는 body에 도달할 수 있으므로 문서 범위로 정규화한다.
document.addEventListener("copy", event => {
  if (view && !isRaw() && copy(event)) event.stopPropagation();
}, true);
window.markAgentEditor = async command => {
  if (command.version !== 1) throw new Error("편집기 protocol version 오류");
  if (command.kind === "initialize") {
    if (editor) throw new Error("중복 initialize");
    sessionID = command.sessionID; epoch = command.epoch; seq = 0;
    configuration = command; source = command.text; retainedSelection = command.selection;
    locked = false; rawState = null;
    await mount();
    if (command.active) view.focus();
    emit("ready");
    return;
  }
  if (!view || sessionID !== command.sessionID) throw new Error("편집기 session 오류");
  if (command.kind !== "apply" && command.epoch !== epoch) throw new Error("편집기 epoch 오류");
  switch (command.kind) {
    case "image": {
      const position = imageRequests.get(command.imageID);
      imageRequests.delete(command.imageID);
      const node = position === undefined ? null : view.state.doc.nodeAt(position);
      if (node?.type.name === "image" && command.src) {
        imageURLs.set(position, command.url);
        view.dispatch(view.state.tr.setNodeMarkup(position, undefined, {...node.attrs, src: command.src}).setMeta("host", true));
      }
      break;
    }
    case "flush":
      await settleComposition();
      snapshot();
      locked = true;
      view.setProps({editable: () => isRaw() && !locked});
      emit("snapshot", {requestID: command.requestID, ...snapshot()});
      break;
    case "apply": {
      await settleComposition();
      if (command.operation === "configure") {
        const oldMode = isRaw(), focused = view.hasFocus(), wasActive = configuration.active;
        snapshot();
        configuration = {...configuration, ...command};
        if (oldMode !== isRaw()) {
          if (oldMode) rawState = view.state.reconfigure({
            plugins: view.state.plugins.filter(plugin => !plugin.key.startsWith("MILKDOWN_"))
          });
          await editor.destroy(); view = null;
          await mount();
          if (focused && configuration.active !== false) {
            if (locked) focusOnResume = true; else view.focus();
          }
        } else theme();
        if (command.active === false) {
          focusOnResume = false;
          if (view.hasFocus()) view.dom.blur();
        }
        if (command.active === true && wasActive === false) {
          if (locked) focusOnResume = true; else view.focus();
        }
      } else {
        const reset = command.operation === "replace";
        if (reset) epoch = command.epoch;
        if (isRaw()) {
          if (reset) {
            source = command.text; retainedSelection = command.selection;
            const state = EditorState.create({schema: view.state.schema,
              doc: view.state.schema.nodeFromJSON(rawJSON(lineMap(source).text)),
              plugins: view.state.plugins.map(plugin => plugin.key === rawKey.key ? rawPlugin(source) : plugin)});
            view.updateState(state.apply(state.tr.setSelection(selectionFor(state.doc, source, retainedSelection))));
          } else {
            view.dispatch(closeHistory(replacement(view.state, command.text, command.selection)).setMeta("host", true));
            view.dispatch(closeHistory(view.state.tr).setMeta("host", true));
          }
          snapshot();
        } else {
          source = command.text; retainedSelection = command.selection;
          if (rawState && !reset) rawState = rawState.apply(closeHistory(replacement(rawState, source, retainedSelection)));
          else rawState = null;
          await editor.destroy(); view = null;
          await mount();
        }
      }
      emit("applied", {requestID: command.requestID});
      break;
    }
    case "resume":
      locked = false;
      view.setProps({editable: () => isRaw() && !locked});
      if (focusOnResume) { focusOnResume = false; view.focus(); }
      break;
    case "dispose":
      await settleComposition();
      await editor.destroy(); editor = null; view = null; rawState = null;
      imageRequests.clear(); imageURLs.clear();
      source = ""; retainedSelection = null; configuration = null;
      break;
    default: throw new Error("알 수 없는 편집기 command");
  }
};
