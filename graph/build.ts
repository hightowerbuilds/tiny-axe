// Builds the viewer into dist/: the server as one file (dist/server.js, with
// its packages inside) and the page (dist/web). `mix tiny_axe.install` copies
// dist/ next to the release.

import { transformAsync } from "@babel/core";
import { build, type Plugin } from "esbuild";
import { cp, mkdir, readFile, rm } from "node:fs/promises";

// The page's .tsx files are Solid: its compiler (a Babel preset) turns JSX
// into DOM updates, then esbuild bundles the result.
const solid: Plugin = {
  name: "solid",
  setup(b) {
    b.onLoad({ filter: /\.tsx$/ }, async ({ path }) => {
      const result = await transformAsync(await readFile(path, "utf8"), {
        filename: path,
        babelrc: false,
        configFile: false,
        presets: ["babel-preset-solid", "@babel/preset-typescript"],
        sourceMaps: "inline",
      });
      return { contents: result!.code!, loader: "js" };
    });
  },
};

await rm("dist", { recursive: true, force: true });
await mkdir("dist/web", { recursive: true });

await build({
  entryPoints: ["src/cli.ts"],
  outfile: "dist/server.js",
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node24",
  logLevel: "warning",
});

await build({
  entryPoints: ["web/app.tsx"],
  plugins: [solid],
  outfile: "dist/web/app.js",
  bundle: true,
  format: "esm",
  target: "es2022",
  minify: true,
  sourcemap: true,
  logLevel: "warning",
});

// The force layout runs in a worker of its own (web/layout.ts).
await build({
  entryPoints: ["web/layout.ts"],
  outfile: "dist/web/layout.js",
  bundle: true,
  format: "esm",
  target: "es2022",
  minify: true,
  sourcemap: true,
  logLevel: "warning",
});

await cp("web/index.html", "dist/web/index.html");
await cp("web/style.css", "dist/web/style.css");
