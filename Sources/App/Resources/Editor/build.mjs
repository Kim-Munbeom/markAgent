import {readdir, rm} from "node:fs/promises";
const result = await Bun.build({
  entrypoints: [import.meta.dir + "/entry.js"], target: "browser", format: "iife",
  minify: true, outdir: import.meta.dir, naming: "editor.js", metafile: true
});
if (!result.success) throw new AggregateError(result.logs, "Milkdown 빌드 실패");
for (const output of Object.values(result.metafile.outputs)) {
  if (output.imports.length) throw new Error("외부 import가 남아 있습니다");
}
if (Object.keys(result.metafile.inputs).some(path => path.includes("@codemirror/"))) {
  throw new Error("주 편집기 번들에 CodeMirror가 포함되었습니다");
}
// 배포 산출물 생성: 라이선스 원문과 SHA256도 같은 빌드에서 생성한다.
let licenses = "";
async function visit(path) {
  for (const item of await readdir(path, {withFileTypes: true})) {
    if (!item.isDirectory() || item.name.startsWith(".")) continue;
    const directory = path + "/" + item.name;
    if (item.name.startsWith("@")) { await visit(directory); continue; }
    const pkg = Bun.file(directory + "/package.json");
    if (!(await pkg.exists())) continue;
    const meta = await pkg.json();
    for (const name of ["LICENSE", "LICENSE.md", "LICENSE.txt"]) {
      const file = Bun.file(directory + "/" + name);
      if (await file.exists()) {
        licenses += `\n## ${meta.name} ${meta.version}\n\n${await file.text()}\n`;
        break;
      }
    }
  }
}
await visit(import.meta.dir + "/node_modules");
await Bun.write(import.meta.dir + "/LICENSES.txt", licenses.replace(/\n+$/, "\n"));
const hash = new Bun.CryptoHasher("sha256").update(await Bun.file(import.meta.dir + "/editor.js").arrayBuffer()).digest("hex");
await Bun.write(import.meta.dir + "/editor.sha256", hash + "  editor.js\n");
console.log("Milkdown offline build OK", hash);
if (process.argv.includes("--clean")) await rm(import.meta.dir + "/node_modules", {recursive: true});
