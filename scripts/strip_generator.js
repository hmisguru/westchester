// Post-build: remove Framework's <meta name="generator"> tag from every built
// page, so the published site doesn't name the tool it was built with.
import {readdir, readFile, writeFile} from "node:fs/promises";
import {join} from "node:path";

const TAG = /^\s*<meta name="generator" content="[^"]*">\n/m;

async function* htmlFiles(dir) {
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) yield* htmlFiles(path);
    else if (entry.name.endsWith(".html")) yield path;
  }
}

for await (const file of htmlFiles("dist")) {
  const html = await readFile(file, "utf8");
  if (TAG.test(html)) await writeFile(file, html.replace(TAG, ""));
}
