// 렌더링 DOM의 의미 구조만 복사한다. 테마와 편집기 metadata는 소유하지 않는다.
export function neutralCopy(root, selection = window.getSelection()) {
  if (!selection?.rangeCount || selection.isCollapsed) return null;
  const range = selection.getRangeAt(0).cloneRange();
  if (!range.intersectsNode(root)) return null;
  const bounds = document.createRange();
  bounds.selectNodeContents(root);
  if (range.compareBoundaryPoints(window.Range.START_TO_START, bounds) < 0) range.setStart(root, 0);
  if (range.compareBoundaryPoints(window.Range.END_TO_END, bounds) > 0) range.setEnd(root, root.childNodes.length);
  if (range.collapsed) return null;
  const box = document.createElement("div");
  let fragment = range.cloneContents();
  let ancestor = range.commonAncestorContainer;
  if (ancestor.nodeType === 3) ancestor = ancestor.parentNode;
  // 한 굵은 글자/코드 블록 내부만 선택해도 공통 조상의 의미 태그를 잃지 않는다.
  while (ancestor && ancestor !== root) {
    const wrapper = ancestor.cloneNode(false);
    wrapper.append(fragment);
    fragment = wrapper;
    ancestor = ancestor.parentNode;
  }
  box.append(fragment);
  const semantic = new Set("P H1 H2 H3 H4 H5 H6 BLOCKQUOTE UL OL LI PRE CODE STRONG EM DEL S A IMG TABLE THEAD TBODY TR TH TD BR HR".split(" "));
  const attributes = {A: ["href", "title"], IMG: ["src", "alt", "title"], OL: ["start"], TD: ["colspan", "rowspan"], TH: ["colspan", "rowspan"]};
  for (const element of [...box.querySelectorAll("*")].reverse()) {
    if (element.matches("script,style,button,input,textarea,select,[data-copy-ignore],.ProseMirror-separator,.ProseMirror-trailingBreak,.ProseMirror-widget")) {
      element.remove(); continue;
    }
    if (!semantic.has(element.tagName)) { element.replaceWith(...element.childNodes); continue; }
    if (element.tagName === "LI" && element.dataset.itemType === "task") {
      element.prepend(document.createTextNode(element.dataset.checked === "true" ? "☑ " : "☐ "));
    }
    for (const attr of [...element.attributes]) {
      if (!(attributes[element.tagName] ?? []).includes(attr.name)) element.removeAttribute(attr.name);
    }
    for (const name of ["href", "src"]) {
      const value = element.getAttribute(name);
      if (value && /^\s*(javascript|vbscript):/i.test(value)) element.removeAttribute(name);
    }
  }
  function text(node) {
    if (node.nodeType === 3) return node.textContent;
    if (node.nodeName === "IMG") return node.getAttribute("alt") ?? "";
    if (node.nodeName === "BR") return "\n";
    if (node.nodeName === "PRE") return node.textContent + "\n";
    const content = [...node.childNodes].map(text).join("");
    if (/^(P|H[1-6]|BLOCKQUOTE|LI|TR)$/.test(node.nodeName)) return content + "\n";
    if (/^(TD|TH)$/.test(node.nodeName)) return content + "\t";
    return content;
  }
  return {html: box.innerHTML, text: text(box).replace(/\t\n/g, "\n").replace(/\n+$/, "")};
}
