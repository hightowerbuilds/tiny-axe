// Builds the viewer into dist/: the server as one file (dist/server.js, with
// its packages inside) and the page (dist/web). `mix tiny_axe.install` copies
// dist/ next to the release.

import { build } from "esbuild";
import { cp, mkdir, rm } from "node:fs/promises";

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
  entryPoints: ["web/app.ts"],
  outfile: "dist/web/app.js",
  bundle: true,
  format: "esm",
  target: "es2022",
  minify: true,
  sourcemap: true,
  logLevel: "warning",
});

await cp("web/index.html", "dist/web/index.html");
await cp("web/style.css", "dist/web/style.css");
