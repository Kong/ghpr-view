import { readFile } from "node:fs/promises";
import { build, transform } from "esbuild";

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node18",
  outfile: "../mcp-ghpr-bundle/index.mjs",
  plugins: [{
    name: "zod-without-runtime-code-generation",
    setup(builder) {
      // Zod's interpreted validator is enabled in the entry point. Also remove
      // access to the Function constructor from its optional compiler modules
      // in the distributed bundle. Escape characters that could change the
      // generated JavaScript source before Zod's compiler sees them.
      builder.onLoad({ filter: /[/\\]node_modules[/\\]zod[/\\]v4[/\\]core[/\\](compile|doc|util)\.js$/ }, async ({ path }) => {
        let source = await readFile(path, "utf8");
        if (path.split(/[\\/]/).at(-1) === "util.js") {
          const vulnerableEsc = `export function esc(str) {\n    return JSON.stringify(str);\n}`;
          const safeEsc = String.raw`export function esc(str) {
    const charMap = {
        "<": "\\u003C",
        ">": "\\u003E",
        "/": "\\u002F",
        "\u2028": "\\u2028",
        "\u2029": "\\u2029",
    };
    return JSON.stringify(str).replace(/[<>/\u2028\u2029]/g, (char) => charMap[char]);
}`;
          if (source.split(vulnerableEsc).length !== 2) {
            throw new Error(`Unexpected Zod esc implementation in ${path}`);
          }
          source = source.replace(vulnerableEsc, safeEsc);
        }
        const { code } = await transform(source, { define: { Function: "undefined" } });
        return { contents: code, loader: "js" };
      });
    },
  }],
});
