// PostToolUse/PreToolUse hook: appends what Claude Code passes to a JSON-lines log.
const input = await new Response(Bun.stdin.stream()).text();
const log = process.env.P0_LOG!;
await Bun.write(Bun.file(log), (await Bun.file(log).exists() ? await Bun.file(log).text() : "") + input.replace(/\n/g, " ") + "\n");
