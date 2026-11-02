// Checks highlight.js auto-detection over SAMPLES and writes hl-fixtures.json (html + expected text) for the Swift HLParse test.
import fs from "fs";
import { SAMPLES } from "./samples.mjs";
import vm from "vm";
// same setup as the Mac app: highlight.min.js then jothl.js in one global context
const ctx = vm.createContext({});
for (const f of ["highlight.min.js", "jothl.js"]) vm.runInContext(fs.readFileSync(new URL("../../Resources/" + f, import.meta.url), "utf8"), ctx);
let bad = 0;
const fixtures = [];
for (const [lang, code] of Object.entries(SAMPLES)) {
  const r = JSON.parse(ctx.jotHighlight(code, ""));
  const ok = r.language === lang;
  if (!ok) bad++;
  console.log(ok ? "ok  " : "MISS", lang.padEnd(11), "->", r.language);
  fixtures.push({ lang, code, html: r.value });
}
fs.writeFileSync(new URL("./hl-fixtures.json", import.meta.url), JSON.stringify(fixtures));
console.log(`${Object.keys(SAMPLES).length - bad}/${Object.keys(SAMPLES).length} detected`);
