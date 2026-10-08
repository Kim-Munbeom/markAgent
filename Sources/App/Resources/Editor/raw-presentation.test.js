import {test, expect, beforeEach, afterEach} from "bun:test";
import {Window} from "happy-dom";
import {Schema} from "@milkdown/kit/prose/model";
import {EditorState, TextSelection} from "@milkdown/kit/prose/state";
import {EditorView} from "@milkdown/kit/prose/view";
import {history, undo, redo, closeHistory} from "@milkdown/kit/prose/history";
import {rawPresentation, rawPresentationKey, sourceLineStarts, syntaxRanges} from "./raw-presentation.js";
import {lineMap, rawPlugin, rawKey, trackRaw, replacement, rawSelection} from "./raw-document.js";
import {rawJSON} from "./raw-schema.js";

const schema = new Schema({nodes: {
  doc: {content: "raw_source"},
  raw_source: {content: "text*", code: true, marks: "", toDOM: () => ["pre", ["code", 0]]},
  text: {}
}});
const keys = ["window", "document", "navigator", "Node", "HTMLElement", "Element",
  "MutationObserver", "getComputedStyle"];
let dom, saved, views, observers;
beforeEach(() => {
  dom = new Window();
  saved = new Map(keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  for (const key of keys) Object.defineProperty(globalThis, key, {
    configurable: true, writable: true,
    value: key === "window" ? dom : key === "getComputedStyle" ? dom[key].bind(dom) : dom[key]
  });
  views = [];
  observers = [];
  // 실제 layout 엔진 대신 명시적인 geometry/resize 신호를 사용한다.
  dom.ResizeObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe(node) { this.target = node; }
    disconnect() { this.target = null; this.callback = null; }
  };
});
afterEach(async () => {
  for (const view of views) if (!view.isDestroyed) view.destroy();
  await dom.happyDOM.abort();
  for (const [key, descriptor] of saved) {
    if (descriptor) Object.defineProperty(globalThis, key, descriptor);
    else delete globalThis[key];
  }
});

function makeState(raw, language = "markdown") {
  return EditorState.create({schema, doc: schema.nodeFromJSON(rawJSON(lineMap(raw).text)),
    plugins: [rawPlugin(raw), rawPresentation(language), history()]});
}
function mount(raw, language = "markdown", editable = true) {
  let tops = sourceLineStarts(lineMap(raw).text).map((_offset, i) => i * 20);
  const parent = document.createElement("div");
  parent.getBoundingClientRect = () => ({top: 100});
  document.body.append(parent);
  class MeasuredView extends EditorView {
    coordsAtPos(position) {
      const starts = sourceLineStarts(this.state.doc.textContent);
      const index = starts.findLastIndex(start => start <= position - 1);
      return {top: 100 + tops[index], bottom: 120 + tops[index], left: 72, right: 72};
    }
  }
  const view = new MeasuredView(parent, {
    state: makeState(raw, language), editable: () => editable,
    dispatchTransaction(tr) { view.updateState(view.state.apply(trackRaw(view.state, tr))); }
  });
  views.push(view);
  const gutter = parent.querySelector(".raw-line-gutter");
  gutter.getBoundingClientRect = () => ({top: 100});
  return {view, parent, gutter,
    resize(values) { tops = values; observers.at(-1).callback(); }};
}

test("빈 원문과 빈 줄, 마지막 개행은 모두 논리 줄로 센다", () => {
  for (const [raw, starts] of [
    ["", [0]], ["\n", [0, 1]], ["\n\n", [0, 1, 2]],
    ["😀\r\n\r\n끝\r", [0, 3, 4, 6]], ["아주 긴 단일 원문", [0]]
  ]) {
    const state = makeState(raw);
    expect(sourceLineStarts(state.doc.textContent)).toEqual(starts);
    expect(rawPresentationKey.getState(state).lines).toEqual(starts);
    expect(rawKey.getState(state)).toBe(raw);
  }
});

test("줄 번호는 contentDOM 밖에서 wrap 및 resize 높이를 따른다", () => {
  const raw = "긴 원문 ".repeat(40) + "\r\n\r\n끝\r\n";
  const {view, gutter, resize} = mount(raw);
  expect(view.dom.contains(gutter)).toBe(false);
  expect(gutter.getAttribute("aria-hidden")).toBe("true");
  expect(gutter.textContent).toBe("");
  expect([...gutter.children].map(row => row.dataset.line)).toEqual(["1", "2", "3", "4"]);
  resize([0, 80, 100, 120]);
  expect([...gutter.children].map(row => row.style.top)).toEqual(["0px", "80px", "100px", "120px"]);
  resize([0, 160, 180, 200]);
  expect(gutter.children[1].style.top).toBe("160px");
  expect(view.dom.textContent).toBe(lineMap(raw).text);
  view.dispatch(view.state.tr.insertText("\n", 1));
  expect(gutter.children.length).toBe(5);
  expect(gutter.lastElementChild.dataset.line).toBe("5");
});

test("gutter의 실제 좌표 원점을 사용해 상단 헤더와 스크롤 오프셋을 분리한다", () => {
  const {gutter, resize} = mount("첫째\n둘째");
  gutter.getBoundingClientRect = () => ({top: 60});
  resize([0, 20]);
  expect(gutter.children[0].style.top).toBe("40px");
  expect(gutter.children[1].style.top).toBe("60px");
});

test("Markdown 토큰은 이모지와 HTML entity 뒤에도 UTF16 범위를 보존한다", () => {
  const text = "😀 & < >\n# 제목\n**굵게** `값` [링크](https://example.com)\n";
  const ranges = syntaxRanges(text, "markdown");
  expect(ranges.some(range => text.slice(range.from - 1, range.to - 1) === "# 제목"
    && range.classes.includes("hljs-section"))).toBe(true);
  expect(ranges.some(range => range.classes.includes("hljs-strong"))).toBe(true);
  for (const range of ranges) {
    expect(range.from).toBeGreaterThanOrEqual(1);
    expect(range.to).toBeLessThanOrEqual(text.length + 1);
  }
  const {view} = mount(text);
  expect(view.dom.textContent).toBe(text);
  expect(view.dom.querySelector(".hljs-section").textContent).toBe("# 제목");
});

test("Swift keyword/string/number 토큰은 혼합 줄끝과 선택 원문에 영향을 주지 않는다", () => {
  const raw = 'let face = "😀 & <한글>"\r\nlet n = 42\r// 끝\n';
  const {view} = mount(raw, "swift");
  const original = view.state.doc.toJSON();
  const tokens = rawPresentationKey.getState(view.state).decorations.find();
  const text = lineMap(raw).text;
  for (const [classes, value] of [["hljs-keyword", "let"], ["hljs-string", '"😀 & <한글>"'], ["hljs-number", "42"]]) {
    expect(tokens.some(token => token.type.attrs.class.includes(classes)
      && text.slice(token.from - 1, token.to - 1) === value)).toBe(true);
  }
  view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, 1, text.length + 1)));
  const range = rawSelection(view.state);
  expect(rawKey.getState(view.state).slice(range.location, range.location + range.length)).toBe(raw);
  expect(view.state.doc.toJSON()).toEqual(original);
  expect(view.dom.querySelectorAll(".raw-line-number").length).toBe(0);
});

test("Swift가 보내는 모든 언어 이름은 오프라인 문법으로 연결된다", () => {
  // 네이티브 enum의 wire 값들이다. 새 enum 추가 시 이 목록도 갱신한다.
  const languages = ["appleScript", "arduino", "astro", "awk", "bash", "basic", "c", "clojure",
    "cpp", "csharp", "css", "dart", "delphi", "diff", "django", "dockerfile", "elixir", "elm",
    "env", "erlang", "gherkin", "go", "gradle", "graphql", "haskell", "html", "java",
    "javascript", "jsx", "json", "jsonc", "jsonl", "julia", "kotlin", "latex", "less",
    "lisp", "lua", "makefile", "markdown", "mathematica", "matlab", "mdx", "nix",
    "objectiveC", "perl", "php", "postgresql", "protobuf", "python", "r", "ruby", "rust",
    "sass", "scala", "scss", "shell", "sql", "svelte", "swift", "toml", "typescript",
    "tsx", "visualBasic", "vue", "webAssembly", "xml", "yaml"];
  // 각 문법에 맞는 소스가 아닐 때도 highlight API 호출을 수행해야 한다.
  for (const language of languages) {
    const ownerDocument = {createElement: document.createElement.bind(document)};
    let calls = 0;
    const original = ownerDocument.createElement;
    ownerDocument.createElement = tag => { calls++; return original(tag); };
    syntaxRanges('let x = "값"; 42 <tag> # title\n', language, ownerDocument);
    expect(calls).toBe(1);
  }
  expect(syntaxRanges("plain", "unsupported-language")).toEqual([]);
  expect(syntaxRanges("# 제목", null)).toEqual(syntaxRanges("# 제목", "markdown"));
});

test("표시 설정 변경과 CRLF undo/redo는 원문 및 선택을 보존한다", () => {
  let state = makeState('let x = "😀"\r\n', "swift");
  const dispatch = tr => { state = state.apply(trackRaw(state, tr)); };
  dispatch(closeHistory(replacement(state, 'let x = 42\r\n\n', {location: 4, length: 1})));
  const selection = state.selection.toJSON(), doc = state.doc.toJSON();
  dispatch(state.tr.setMeta(rawPresentationKey, {language: "javascript"}).setMeta("addToHistory", false));
  expect(state.doc.toJSON()).toEqual(doc);
  expect(state.selection.toJSON()).toEqual(selection);
  expect(rawPresentationKey.getState(state).language).toBe("javascript");
  expect(undo(state, dispatch)).toBe(true);
  expect(rawKey.getState(state)).toBe('let x = "😀"\r\n');
  expect(rawPresentationKey.getState(state).lines.length).toBe(2);
  expect(redo(state, dispatch)).toBe(true);
  expect(rawKey.getState(state)).toBe('let x = 42\r\n\n');
  expect(rawPresentationKey.getState(state).lines.length).toBe(3);
});

test("IME 중에는 장식을 매핑하고 종료 신호 뒤에만 재토큰화한다", async () => {
  const {view} = mount("let x = 1\r\n", "swift");
  const plugin = view.state.plugins.find(plugin => plugin.key === rawPresentationKey.key);
  plugin.props.handleDOMEvents.compositionstart(view);
  view.dispatch(view.state.tr.insertText("한글😀", 1).setMeta("composition", 1));
  expect(rawKey.getState(view.state)).toBe("한글😀let x = 1\r\n");
  const selected = view.state.selection.toJSON(), raw = rawKey.getState(view.state);
  const refreshed = new Promise(resolve => {
    const dispatch = view.dispatch;
    view.dispatch = tr => {
      dispatch(tr);
      if (tr.getMeta(rawPresentationKey)?.refresh) resolve();
    };
  });
  plugin.props.handleDOMEvents.compositionend(view);
  await refreshed;
  expect(rawKey.getState(view.state)).toBe(raw);
  expect(view.state.selection.toJSON()).toEqual(selected);
  expect(view.state.doc.textContent).toBe(lineMap(raw).text);
});

test("읽기 전용 raw도 표시하며 Preview 스키마에는 장식하지 않는다", () => {
  const {view, gutter} = mount("# 제목\n", "markdown", false);
  expect(view.editable).toBe(false);
  expect(gutter.children.length).toBe(2);
  expect(view.dom.querySelector(".hljs-section")).not.toBeNull();
  const previewSchema = new Schema({nodes: {doc: {content: "paragraph"}, paragraph: {content: "text*"}, text: {}}});
  const state = EditorState.create({schema: previewSchema,
    doc: previewSchema.node("doc", null, [previewSchema.node("paragraph", null, previewSchema.text("# 제목"))]),
    plugins: [rawPresentation("markdown")]});
  expect(rawPresentationKey.getState(state).lines).toEqual([]);
  expect(rawPresentationKey.getState(state).decorations.find()).toEqual([]);
});

test("destroy는 gutter와 ResizeObserver를 해제하고 대기 중 IME 갱신을 취소한다", async () => {
  const {view, parent} = mount("# 제목\n");
  const plugin = view.state.plugins.find(plugin => plugin.key === rawPresentationKey.key);
  plugin.props.handleDOMEvents.compositionstart(view);
  plugin.props.handleDOMEvents.compositionend(view);
  view.destroy();
  await Promise.resolve();
  expect(parent.querySelector(".raw-line-gutter")).toBeNull();
  expect(observers.at(-1).target).toBeNull();
  expect(observers.at(-1).callback).toBeNull();
});

test("브라우저 번들은 외부 import와 CodeMirror 없이 메모리에서 생성된다", async () => {
  const result = await Bun.build({entrypoints: [import.meta.dir + "/raw-presentation.js"],
    target: "browser", format: "iife", minify: true, metafile: true, write: false});
  expect(result.success).toBe(true);
  expect(Object.values(result.metafile.outputs).every(output => output.imports.length === 0)).toBe(true);
  expect(Object.keys(result.metafile.inputs).some(path => path.includes("@codemirror/"))).toBe(false);
  expect(Object.keys(result.metafile.inputs).some(path => path.includes("highlight.js"))).toBe(true);
});
