// A stand-in gate: an MCP server (stdio) with one tool, chrome_permission, for
// --permission-prompt-tool. Logs every question; holds the first click on a
// ref the hook log says is labelled "Place order"; allows everything else.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
const LOG = process.env.P0_GATE_LOG!, HOOKS = process.env.P0_LOG!;
let held = false;
const out = (m: unknown) => process.stdout.write(JSON.stringify(m) + "\n");
function labelOf(ref: string): string | null {
  if (!existsSync(HOOKS)) return null;
  const text = readFileSync(HOOKS, "utf8");
  // Results mention refs next to their labels; find the line with this ref.
  const i = text.lastIndexOf(ref);
  return i < 0 ? null : text.slice(Math.max(0, i - 200), i + 200);
}
function decide(args: any) {
  const input = args.input ?? {};
  const ref = input.ref ?? input.element_ref ?? null;
  if (!held && args.tool_name?.endsWith("__computer") && /click/.test(input.action ?? "") && ref) {
    const around = labelOf(String(ref)) ?? "";
    if (/place order/i.test(around)) {
      held = true;
      return { behavior: "deny", message: "tiny-axe holds this order: call get_page_text on this tab first, then click Place order again." };
    }
  }
  return { behavior: "allow", updatedInput: input };
}
let buf = "";
const BLOCK = Number(process.env.P0_BLOCK_MS ?? 0);
process.stdin.on("data", (d) => {
  buf += d;
  let n;
  while ((n = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, n); buf = buf.slice(n + 1);
    if (!line.trim()) continue;
    const msg = JSON.parse(line);
    if (msg.method === "initialize") out({ jsonrpc: "2.0", id: msg.id, result: { protocolVersion: msg.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "p0gate", version: "0" } } });
    else if (msg.method === "tools/list") out({ jsonrpc: "2.0", id: msg.id, result: { tools: [{ name: "chrome_permission", description: "Decides whether a tool call may run.", inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } }, required: ["tool_name", "input"] } }] } });
    else if (msg.method === "tools/call") {
      const args = msg.params.arguments;
      const input = args.input ?? {};
      // With P0_BLOCK_MS: answer a click only after that long (a person deciding), then allow it.
      const slow = BLOCK > 0 && /click/.test(input.action ?? "");
      const decision = slow ? { behavior: "allow", updatedInput: input } : decide(args);
      const answer = () => {
        appendFileSync(LOG, JSON.stringify({ at: new Date().toISOString(), args, decision, waited: slow ? BLOCK : 0 }) + "\n");
        out({ jsonrpc: "2.0", id: msg.id, result: { content: [{ type: "text", text: JSON.stringify(decision) }] } });
      };
      if (slow) setTimeout(answer, BLOCK); else answer();
    } else if (msg.id !== undefined) out({ jsonrpc: "2.0", id: msg.id, result: {} });
  }
});
