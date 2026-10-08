import {Plugin, PluginKey, TextSelection} from "@milkdown/kit/prose/state";
import {Step, StepResult} from "@milkdown/kit/prose/transform";

// PM 좌표는 단일 code 노드 안의 LF UTF-16 + 1, wire는 원문 UTF-16이다.
export function lineMap(raw) {
  const rawStarts = [0], textStarts = [0], separators = [];
  let text = "", start = 0;
  for (const match of raw.matchAll(/\r\n|\r|\n/g)) {
    text += raw.slice(start, match.index) + "\n";
    separators.push(match[0]);
    start = match.index + match[0].length;
    rawStarts.push(start);
    textStarts.push(text.length);
  }
  text += raw.slice(start);
  function lineAt(starts, offset) {
    let lo = 0, hi = starts.length;
    while (lo + 1 < hi) {
      const mid = (lo + hi) >> 1;
      if (starts[mid] <= offset) lo = mid; else hi = mid;
    }
    return lo;
  }
  return {text, separators,
    toRaw(offset) {
      offset = Math.max(0, Math.min(text.length, offset));
      const line = lineAt(textStarts, offset);
      return rawStarts[line] + offset - textStarts[line];
    },
    toText(offset) {
      offset = Math.max(0, Math.min(raw.length, offset));
      const line = lineAt(rawStarts, offset);
      const end = line + 1 < textStarts.length ? textStarts[line + 1] - 1 : text.length;
      return Math.min(end, textStarts[line] + offset - rawStarts[line]);
    }
  };
}

// 줄끝 metadata도 PM history의 같은 transaction에서 역전된다.
export class RawStep extends Step {
  constructor(before, after) { super(); this.before = before; this.after = after; }
  apply(doc) { return StepResult.ok(doc); }
  invert() { return new RawStep(this.after, this.before); }
  map() { return this; }
  toJSON() { return {stepType: "markAgentRaw", before: this.before, after: this.after}; }
  static fromJSON(_schema, value) { return new RawStep(value.before, value.after); }
}
Step.jsonID("markAgentRaw", RawStep);
export const rawKey = new PluginKey("markAgentRaw");
export function rawPlugin(raw) {
  return new Plugin({key: rawKey, state: {
    init: () => raw,
    apply: (tr, value) => tr.steps.filter(step => step instanceof RawStep).at(-1)?.after ?? value
  }});
}
export function trackRaw(state, tr) {
  if (!tr.docChanged || tr.steps.some(step => step instanceof RawStep)) return tr;
  const before = rawKey.getState(state);
  let raw = before;
  tr.steps.forEach((step, index) => {
    const map = lineMap(raw), afterDoc = tr.docs[index + 1] ?? tr.doc;
    let next = "", cursor = 0;
    step.getMap().forEach((from, to, newFrom, newTo) => {
      const rawFrom = map.toRaw(from - 1), rawTo = map.toRaw(to - 1);
      const inserted = afterDoc.textBetween(newFrom, newTo, "").replace(/\n/g, map.separators[0] ?? "\n");
      next += raw.slice(cursor, rawFrom) + inserted;
      cursor = rawTo;
    });
    raw = next + raw.slice(cursor);
  });
  return tr.step(new RawStep(before, raw));
}
export function rawSelection(state) {
  const map = lineMap(rawKey.getState(state));
  const start = map.toRaw(state.selection.from - 1), end = map.toRaw(state.selection.to - 1);
  return {location: start, length: end - start};
}
export function selectionFor(doc, raw, selection) {
  const map = lineMap(raw);
  return TextSelection.create(doc, map.toText(selection.location) + 1,
    map.toText(selection.location + selection.length) + 1);
}
export function replacement(state, raw, selection) {
  const before = state.doc.textContent, after = lineMap(raw).text;
  let from = 0, endBefore = before.length, endAfter = after.length;
  while (from < endBefore && from < endAfter && before[from] === after[from]) from++;
  while (endBefore > from && endAfter > from && before[endBefore - 1] === after[endAfter - 1]) {
    endBefore--; endAfter--;
  }
  const tr = state.tr;
  if (from !== endBefore || from !== endAfter) tr.insertText(after.slice(from, endAfter), from + 1, endBefore + 1);
  tr.step(new RawStep(rawKey.getState(state), raw));
  return tr.setSelection(selectionFor(tr.doc, raw, selection));
}
