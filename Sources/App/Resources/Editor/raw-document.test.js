import {test, expect} from "bun:test";
import {EditorState} from "@milkdown/kit/prose/state";
import {Schema} from "@milkdown/kit/prose/model";
import {history, undo, redo, closeHistory} from "@milkdown/kit/prose/history";
import {lineMap, rawPlugin, rawKey, replacement, trackRaw, rawSelection} from "./raw-document.js";
import {rawJSON} from "./raw-schema.js";

const schema = new Schema({nodes: {doc: {content: "raw_source"},
  raw_source: {content: "text*", code: true}, text: {}}});
test("혼합 줄끝과 UTF16 좌표의 앞 boundary", () => {
  const map = lineMap("😀\r\n한글\nx\ry\r\n");
  expect(map.text).toBe("😀\n한글\nx\ny\n");
  expect(map.toText(3)).toBe(2);
  expect(map.toText(4)).toBe(3);
  expect(map.toRaw(3)).toBe(4);
});
test("Enter, paste, format undo가 원문 separator를 복원한다", () => {
  const raw = "😀\r\n한글\nx\ry\r\n";
  let state = EditorState.create({schema, doc: schema.nodeFromJSON(rawJSON(lineMap(raw).text)),
    plugins: [rawPlugin(raw), history()]});
  const dispatch = tr => { state = state.apply(trackRaw(state, tr)); };
  dispatch(closeHistory(state.tr.insertText("\n", 3)));
  expect(rawKey.getState(state)).toBe("😀\r\n\r\n한글\nx\ry\r\n");
  expect(undo(state, dispatch)).toBe(true);
  expect(rawKey.getState(state)).toBe(raw);
  expect(redo(state, dispatch)).toBe(true);
  expect(rawKey.getState(state)).toBe("😀\r\n\r\n한글\nx\ry\r\n");
  undo(state, dispatch);
  const pasted = "😀\r\n붙임\n혼합\r\n한글\nx\ry\r\n";
  dispatch(closeHistory(replacement(state, pasted, {location: 8, length: 0})));
  expect(rawKey.getState(state)).toBe(pasted);
  expect(rawSelection(state)).toEqual({location: 8, length: 0});
  undo(state, dispatch);
  expect(rawKey.getState(state)).toBe(raw);
});
test("줄끝만 다른 호스트 replacement도 독립적으로 undo 된다", () => {
  let state = EditorState.create({schema, doc: schema.nodeFromJSON(rawJSON("a\nb")),
    plugins: [rawPlugin("a\r\nb"), history()]});
  const dispatch = tr => { state = state.apply(trackRaw(state, tr)); };
  dispatch(closeHistory(replacement(state, "a\nb", {location: 2, length: 1})));
  expect(rawKey.getState(state)).toBe("a\nb");
  expect(undo(state, dispatch)).toBe(true);
  expect(rawKey.getState(state)).toBe("a\r\nb");
});
