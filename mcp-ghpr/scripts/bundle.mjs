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
      // in the distributed bundle.
      builder.onLoad({ filter: /[/\\]node_modules[/\\]zod[/\\]v4[/\\]core[/\\](compile|doc|util)\.js$/ }, async ({ path }) => {
        const source = await readFile(path, "utf8");
        const { code } = await transform(source, { define: { Function: "undefined" } });
        return { contents: code, loader: "js" };
      });
    },
  }],
});
