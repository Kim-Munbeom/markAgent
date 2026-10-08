import {Plugin, PluginKey} from "@milkdown/kit/prose/state";
import {Decoration, DecorationSet} from "@milkdown/kit/prose/view";
import hljs from "highlight.js";

// Swift의 CodeHighlightLanguage 이름을 highlight.js 문법에 연결한다.
// 복합 템플릿은 기본 문법으로 표시하며 원문을 변환하지 않는다.
const aliases = {
  astro: "xml",
  env: "ini", html: "xml", jsx: "javascript", jsonc: "json", jsonl: "json",
  latex: "latex", mdx: "markdown", objectivec: "objectivec", postgresql: "pgsql",
  sass: "scss", shell: "bash", svelte: "xml", toml: "ini", tsx: "typescript",
  visualbasic: "vbnet", vue: "xml", webassembly: "wasm"
};

export const rawPresentationKey = new PluginKey("markAgentRawPresentation");

// PM 문서의 LF UTF16 좌표를 사용한다. 화면 줄바꿈은 새 논리 줄이 아니다.
export function sourceLineStarts(text) {
  const starts = [0];
  for (let offset = 0; offset < text.length; offset++) {
    if (text[offset] === "\n") starts.push(offset + 1);
  }
  return starts;
}

export function syntaxRanges(text, language, ownerDocument = globalThis.document) {
  const name = (language ?? "markdown").toLowerCase();
  const grammar = aliases[name] ?? name;
  if (!text || !hljs.getLanguage(grammar)) return [];
  // 공개 API의 HTML을 분리된 DOM에서 읽는다. 편집 DOM에 삽입하지 않는다.
  const template = ownerDocument.createElement("template");
  template.innerHTML = hljs.highlight(text, {language: grammar, ignoreIllegals: true}).value;
  const ranges = [];
  let offset = 0;
  function walk(node, classes = "") {
    if (node.nodeType === 3) {
      const end = offset + node.nodeValue.length;
      if (classes && end > offset) ranges.push({from: offset + 1, to: end + 1, classes});
      offset = end;
    } else {
      const own = node.nodeType === 1 ? node.getAttribute("class") : null;
      for (const child of node.childNodes) walk(child, own || classes);
    }
  }
  walk(template.content);
  return ranges;
}

function presentation(doc, language) {
  if (doc.firstChild?.type.name !== "raw_source") {
    return {language, lines: [], decorations: DecorationSet.empty};
  }
  const text = doc.textContent;
  const decorations = syntaxRanges(text, language).map(range =>
    Decoration.inline(range.from, range.to, {class: `raw-syntax ${range.classes}`}));
  return {language, lines: sourceLineStarts(text), decorations: DecorationSet.create(doc, decorations)};
}

// 줄 번호는 contentDOM 바깥에 둔다. 복사/선택/IME에 widget 문자가 섞이지 않는다.
export function rawPresentation(language) {
  let composing = false, alive = false;
  return new Plugin({
    key: rawPresentationKey,
    state: {
      init: (_config, state) => presentation(state.doc, language),
      apply(tr, value) {
        const update = tr.getMeta(rawPresentationKey);
        const nextLanguage = update && "language" in update ? update.language : value.language;
        if (composing && !update?.refresh) {
          return {...value, language: nextLanguage, lines: sourceLineStarts(tr.doc.textContent),
            decorations: value.decorations.map(tr.mapping, tr.doc)};
        }
        if (tr.docChanged || update?.refresh || nextLanguage !== value.language) {
          return presentation(tr.doc, nextLanguage);
        }
        return value;
      }
    },
    props: {
      decorations: state => rawPresentationKey.getState(state).decorations,
      handleDOMEvents: {
        compositionstart() { composing = true; return false; },
        compositionend(view) {
          queueMicrotask(() => {
            if (!alive) return;
            composing = false;
            view.dispatch(view.state.tr.setMeta(rawPresentationKey, {refresh: true})
              .setMeta("addToHistory", false));
          });
          return false;
        }
      }
    },
    view(view) {
      alive = true;
      const owner = view.dom.ownerDocument, parent = view.dom.parentElement;
      const gutter = owner.createElement("div");
      gutter.className = "raw-line-gutter";
      gutter.setAttribute("aria-hidden", "true");
      gutter.setAttribute("contenteditable", "false");
      parent.append(gutter);
      function update() {
        const {lines} = rawPresentationKey.getState(view.state);
        while (gutter.children.length > lines.length) gutter.lastElementChild.remove();
        while (gutter.children.length < lines.length) {
          const row = owner.createElement("div");
          row.className = "raw-line-number";
          row.dataset.line = String(gutter.children.length + 1);
          gutter.append(row);
        }
        const origin = gutter.getBoundingClientRect().top;
        lines.forEach((offset, index) => {
          // 실제 첫 글자의 높이를 사용하므로 긴 줄의 wrap/폰트/폭 변경을 따른다.
          const top = view.coordsAtPos(offset + 1, 1).top - origin;
          gutter.children[index].style.top = `${top}px`;
        });
      }
      const Observer = owner.defaultView.ResizeObserver;
      const observer = new Observer(update);
      observer.observe(view.dom);
      update();
      return {
        update,
        destroy() { alive = false; composing = false; observer.disconnect(); gutter.remove(); }
      };
    }
  });
}
