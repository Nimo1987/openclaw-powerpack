#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# OpenClaw PowerPack — One-click installer
#
# Installs 4 components:
#   1. Step Gate   — Internal Hook + Plugin (task execution discipline)
#   2. Mode Gate   — Internal Hook (A/B/C mode routing)
#   3. Skill Runner — Workflow execution engine (lib)
#   4. Workflow Builder — Skill for creating new workflows
#
# Usage:
#   curl -sL <url>/install.sh | sudo bash
#   or: sudo bash install.sh
#
# Requires: OpenClaw installed and running
# ─────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}\n"; }

# ── Detect install source (git clone or curl pipe) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/step-gate/hook/handler.js" ]; then
    SRC_DIR="$SCRIPT_DIR"
    info "Installing from local directory: $SRC_DIR"
else
    SRC_DIR=""
    info "Installing via inline mode (curl pipe)"
fi

# ── Check environment ──
OC_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
OC_CONFIG="$OC_DIR/openclaw.json"
OC_WORKSPACE="${OPENCLAW_WORKSPACE:-$OC_DIR/workspace}"
OC_EXTENSIONS="$OC_DIR/extensions"
OC_HOOKS="$OC_DIR/hooks"

[ -d "$OC_DIR" ] || error "OpenClaw directory not found: $OC_DIR"
[ -f "$OC_CONFIG" ] || error "OpenClaw config not found: $OC_CONFIG"

info "OpenClaw detected: $OC_DIR"

# ══════════════════════════════════════════════════════════════
section "1/4  Step Gate (Internal Hook + Plugin)"
# ══════════════════════════════════════════════════════════════

# ── Hook ──
HOOK_DIR="$OC_HOOKS/step-gate"
mkdir -p "$HOOK_DIR"

if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/step-gate/hook/HOOK.md" "$HOOK_DIR/HOOK.md"
    cp "$SRC_DIR/step-gate/hook/handler.js" "$HOOK_DIR/handler.js"
else
    # Inline HOOK.md
    cat > "$HOOK_DIR/HOOK.md" << 'HOOKMD_EOF'
---
name: step-gate
description: "Inject STEP-GATE.md into agent bootstrap context to enforce step execution discipline"
metadata:
  {
    "openclaw":
      {
        "emoji": "🚦",
        "events": ["agent:bootstrap"],
        "always": true,
      },
  }
---
# Step Gate — Bootstrap Hook

Injects `STEP-GATE.md` into the agent's bootstrap context on every session start.

Scans workspace for active `todo*.md` files, builds a progress summary with step-by-step
execution rules, and prepends it to `bootstrapFiles` so the agent sees it first.

Works together with the step-gate plugin (periodic checkbox sync).
HOOKMD_EOF

    # Inline handler.js
    cat > "$HOOK_DIR/handler.js" << 'HANDLER_EOF'
/**
 * Step Gate — Internal Hook Handler (v11)
 *
 * Listens to agent:bootstrap events and injects STEP-GATE.md
 * into the agent's bootstrap context.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";

function D(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [hook] ${msg}\n`);
  } catch {}
}

function parseSteps(content) {
  const steps = [];
  const lines = content.split("\n");
  const cbRe = /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;

  for (const line of lines) {
    const cb = line.match(cbRe);
    if (!cb) continue;
    const mark = cb[1], start = +cb[2], end = cb[3] ? +cb[3] : start, title = cb[4].trim();
    const status = mark === "x" || mark === "X" ? "done" : mark === "~" ? "in-progress" : "pending";
    for (let n = start; n <= end; n++) {
      if (!steps.find((x) => x.number === n)) steps.push({ number: n, title, status });
    }
  }

  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe = /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1], block = m[0].toLowerCase();
      if (block.includes("status: done") || block.includes("status: completed") || block.includes("status: 完成")) {
        const st = steps.find((x) => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }
  return steps;
}

function isFileCompleted(content) {
  const header = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return header.includes("status: completed") || header.includes("status: done") || header.includes("status: 已完成");
}

function analyze(fp) {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;
    const done = steps.filter((s) => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);
    let current = null;
    for (const s of sorted) { if (s.status !== "done") { current = s.number; break; } }
    const skipped = [];
    let lastDone = 0;
    for (const s of sorted) {
      if (s.status === "done") {
        for (let n = lastDone + 1; n < s.number; n++) {
          const x = steps.find((y) => y.number === n);
          if (x && x.status === "pending") skipped.push(n);
        }
        lastDone = s.number;
      }
    }
    return { path: fp, filename: path.basename(fp), steps, total: steps.length, done, current, skipped, fileCompleted };
  } catch { return null; }
}

function scanDir(dir, results) {
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
      const fp = path.join(dir, f);
      try { if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue; } catch { continue; }
      if (results.find((r) => r.path === fp)) continue;
      const t = analyze(fp);
      if (t) results.push(t);
    }
  } catch {}
}

function findTodos(dir) {
  const results = [];
  scanDir(dir, results);
  scanDir(path.join(dir, "todos"), results);
  return results.sort((a, b) => {
    try { return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs; } catch { return 0; }
  });
}

function generateBootstrap(todos, minSteps) {
  const active = todos.filter((t) => !t.fileCompleted && t.total >= minSteps && t.done < t.total);
  if (!active.length) return null;
  const lines = [
    "# STEP GATE — Task Execution Discipline", "",
    "## Rules", "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.", "",
  ];
  for (const t of active) {
    lines.push(`## ${t.filename} (${t.done}/${t.total})`, "");
    for (const s of t.steps.sort((a, b) => a.number - b.number)) {
      const icon = s.status === "done" ? "✅" : "⬜";
      const marker = s.number === t.current ? " **← NOW**" : "";
      lines.push(`${icon} Step ${s.number}: ${s.title}${marker}`);
    }
    lines.push("");
    if (t.skipped.length) lines.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    if (t.current) lines.push(`**→ Execute Step ${t.current} now.**`, "");
  }
  return lines.join("\n");
}

const MIN_STEPS = 3;

const stepGateBootstrapHandler = async (event) => {
  if (event.type !== "agent" || event.action !== "bootstrap") return;

  D("bootstrap FIRED");
  const context = event.context ?? {};
  const workspaceDir = context.workspaceDir || process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");

  const todos = findTodos(workspaceDir);
  D(`found ${todos.length} todos (${todos.filter((t) => t.fileCompleted).length} completed)`);
  if (!todos.length) return;

  const content = generateBootstrap(todos, MIN_STEPS);
  if (!content) { D("no active todos need injection, skip"); return; }

  const fp = path.join(workspaceDir, "STEP-GATE.md");
  try { fs.writeFileSync(fp, content, "utf-8"); } catch (e) { D(`write err: ${e.message}`); }

  const bf = context.bootstrapFiles;
  if (Array.isArray(bf)) {
    const idx = bf.findIndex((f) => f.name === "STEP-GATE.md" || f.path?.endsWith("STEP-GATE.md"));
    if (idx >= 0) bf.splice(idx, 1);
    bf.unshift({ name: "STEP-GATE.md", path: fp, content, source: "step-gate" });
    D(`injected STEP-GATE.md (${bf.length} total bootstrap files)`);
  } else {
    D("WARNING: bootstrapFiles not found in event.context");
  }
};

export default stepGateBootstrapHandler;
HANDLER_EOF
fi

info "Step Gate hook installed → $HOOK_DIR"

# ── Plugin (periodic checkbox sync) ──
PLUGIN_DIR="$OC_EXTENSIONS/step-gate"
mkdir -p "$PLUGIN_DIR"

cat > "$PLUGIN_DIR/openclaw.plugin.json" << 'MANIFEST_EOF'
{
  "id": "step-gate",
  "name": "Step Gate",
  "description": "Periodic checkbox sync for todo-based step execution. Bootstrap injection handled by Internal Hook.",
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {
      "enabled": {
        "type": "boolean",
        "description": "Enable or disable checkbox sync"
      },
      "minSteps": {
        "type": "number",
        "description": "Minimum steps to trigger enforcement (default: 3)"
      },
      "syncInterval": {
        "type": "number",
        "description": "Checkbox sync interval in ms (default: 15000)"
      }
    }
  }
}
MANIFEST_EOF

cat > "$PLUGIN_DIR/package.json" << 'PKG_EOF'
{
  "name": "step-gate",
  "version": "11.0.0",
  "type": "module"
}
PKG_EOF

cat > "$PLUGIN_DIR/index.ts" << 'PLUGIN_EOF'
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";
function D(msg: string): void {
  try { fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [plugin] ${msg}\n`); } catch {}
}

interface Step { number: number; title: string; status: "done" | "pending" | "in-progress"; }
interface Todo { path: string; filename: string; steps: Step[]; total: number; done: number; current: number | null; skipped: number[]; fileCompleted: boolean; }

function parseSteps(content: string): Step[] {
  const steps: Step[] = [];
  const cbRe = /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;
  for (const line of content.split("\n")) {
    const cb = line.match(cbRe);
    if (!cb) continue;
    const mark = cb[1], start = +cb[2], end = cb[3] ? +cb[3] : start, title = cb[4].trim();
    const status: Step["status"] = mark === "x" || mark === "X" ? "done" : mark === "~" ? "in-progress" : "pending";
    for (let n = start; n <= end; n++) if (!steps.find(x => x.number === n)) steps.push({ number: n, title, status });
  }
  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe = /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1], block = m[0].toLowerCase();
      if (block.includes("status: done") || block.includes("status: completed") || block.includes("status: 完成")) {
        const st = steps.find(x => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }
  return steps;
}

function isFileCompleted(content: string): boolean {
  const h = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return h.includes("status: completed") || h.includes("status: done") || h.includes("status: 已完成");
}

function analyze(fp: string): Todo | null {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;
    const done = steps.filter(s => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);
    let current: number | null = null;
    for (const s of sorted) if (s.status !== "done") { current = s.number; break; }
    const skipped: number[] = [];
    let lastDone = 0;
    for (const s of sorted) if (s.status === "done") { for (let n = lastDone + 1; n < s.number; n++) { const x = steps.find(y => y.number === n); if (x && x.status === "pending") skipped.push(n); } lastDone = s.number; }
    return { path: fp, filename: path.basename(fp), steps, total: steps.length, done, current, skipped, fileCompleted };
  } catch { return null; }
}

function findTodos(dir: string): Todo[] {
  const r: Todo[] = [];
  for (const d of [dir, path.join(dir, "todos")]) {
    try {
      for (const f of fs.readdirSync(d)) {
        if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
        const fp = path.join(d, f);
        try { if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue; } catch { continue; }
        if (r.find(x => x.path === fp)) continue;
        const t = analyze(fp);
        if (t) r.push(t);
      }
    } catch {}
  }
  return r.sort((a, b) => { try { return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs; } catch { return 0; } });
}

function syncCheckboxes(fp: string, steps: Step[]): boolean {
  try {
    let c = fs.readFileSync(fp, "utf-8"), changed = false;
    for (const s of steps) {
      if (s.status !== "done") continue;
      const patterns = [
        new RegExp(`(- \\[) (\\]\\s*${s.number}\\.\\s*)`, "m"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}[.:]\\s*)`, "mi"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}\\s*[-–]\\s*\\d+[.:]\\s*)`, "mi"),
      ];
      for (const p of patterns) if (p.test(c)) { c = c.replace(p, "$1x$2"); changed = true; D(`cb:${s.number}`); break; }
    }
    if (steps.length && steps.every(s => s.status === "done") && /# Status: In Progress/i.test(c)) {
      c = c.replace(/# Status: In Progress/i, "# Status: Completed"); changed = true;
    }
    if (changed) fs.writeFileSync(fp, c, "utf-8");
    return changed;
  } catch { return false; }
}

function generateBootstrap(todos: Todo[], minSteps: number): string | null {
  const active = todos.filter(t => !t.fileCompleted && t.total >= minSteps && t.done < t.total);
  if (!active.length) return null;
  const lines: string[] = ["# STEP GATE — Task Execution Discipline", "", "## Rules", "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.", ""];
  for (const t of active) {
    lines.push(`## ${t.filename} (${t.done}/${t.total})`, "");
    for (const s of t.steps.sort((a, b) => a.number - b.number))
      lines.push(`${s.status === "done" ? "✅" : "⬜"} Step ${s.number}: ${s.title}${s.number === t.current ? " **← NOW**" : ""}`);
    lines.push("");
    if (t.skipped.length) lines.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    if (t.current) lines.push(`**→ Execute Step ${t.current} now.**`, "");
  }
  return lines.join("\n");
}

function syncAll(dir: string, minSteps: number): void {
  const todos = findTodos(dir);
  for (const t of todos) syncCheckboxes(t.path, t.steps);
  const content = generateBootstrap(todos, minSteps);
  if (content) try { fs.writeFileSync(path.join(dir, "STEP-GATE.md"), content, "utf-8"); } catch {}
  else try { fs.unlinkSync(path.join(dir, "STEP-GATE.md")); } catch {}
}

export default function register(api: any) {
  const cfg = api.pluginConfig ?? {};
  const enabled = cfg.enabled !== false;
  const minSteps = cfg.minSteps ?? 3;
  const syncInterval = cfg.syncInterval ?? 15000;
  D("=== step-gate v11 register() ===");
  if (!enabled) return;
  const wsDir = (): string => process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");
  setInterval(() => { try { syncAll(wsDir(), minSteps); } catch (e: any) { D(`sync err: ${e.message}`); } }, syncInterval);
  D("v11 loaded (checkbox-sync only, bootstrap via Internal Hook)");
  api.logger?.info?.("step-gate v11 loaded");
}
PLUGIN_EOF

info "Step Gate plugin installed → $PLUGIN_DIR"

# ══════════════════════════════════════════════════════════════
section "2/4  Mode Gate (Internal Hook)"
# ══════════════════════════════════════════════════════════════

MODE_HOOK_DIR="$OC_HOOKS/mode-gate"
mkdir -p "$MODE_HOOK_DIR"

if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/mode-gate/hook/HOOK.md" "$MODE_HOOK_DIR/HOOK.md"
    cp "$SRC_DIR/mode-gate/hook/handler.js" "$MODE_HOOK_DIR/handler.js"
else
    cat > "$MODE_HOOK_DIR/HOOK.md" << 'HOOKMD_EOF'
---
name: mode-gate
description: "Inject MODE-GATE.md into agent bootstrap context for A/B/C mode routing"
metadata:
  {
    "openclaw":
      {
        "emoji": "🔀",
        "events": ["agent:bootstrap"],
        "always": true,
      },
  }
---
# Mode Gate — Bootstrap Hook

Scans `workflows/*.py` for docstrings, builds a complete Mode A/B/C routing
decision table, and injects it as `MODE-GATE.md` into `bootstrapFiles`.

The agent sees this routing table first and knows which execution mode to use
before doing anything else.
HOOKMD_EOF

    cat > "$MODE_HOOK_DIR/handler.js" << 'HANDLER_EOF'
/**
 * Mode Gate — Internal Hook Handler
 *
 * Listens to agent:bootstrap events and injects MODE-GATE.md
 * into the agent's bootstrap context.
 *
 * Scans workflows/*.py, extracts docstrings, builds a complete
 * Mode A/B/C routing decision table.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

const DEBUG_LOG = process.env.MODE_GATE_LOG || "/tmp/mode-gate.log";

function D(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [mode-gate] ${msg}\n`);
  } catch {}
}

function parseWorkflow(filePath) {
  try {
    const content = fs.readFileSync(filePath, "utf-8");
    const lines = content.split("\n").slice(0, 50);
    const info = {
      name: path.basename(filePath, ".py"),
      path: filePath,
      triggers: [],
      description: "",
      invocation: "",
    };

    let inDocstring = false;
    let docLines = [];

    for (const line of lines) {
      const trimmed = line.trim();
      if (!inDocstring) {
        if (trimmed.startsWith('"""') || trimmed.startsWith("'''")) {
          inDocstring = true;
          const rest = trimmed.slice(3);
          if (rest.endsWith('"""') || rest.endsWith("'''")) {
            docLines.push(rest.slice(0, -3));
            break;
          }
          if (rest) docLines.push(rest);
        }
      } else {
        if (trimmed.endsWith('"""') || trimmed.endsWith("'''")) {
          const rest = trimmed.slice(0, -3);
          if (rest) docLines.push(rest);
          break;
        }
        docLines.push(trimmed);
      }
    }

    if (!docLines.length) return null;

    for (const line of docLines) {
      const lower = line.toLowerCase();
      if (lower.startsWith("触发词") || lower.startsWith("triggers")) {
        const val = line.split(/[:：]/)[1];
        if (val) info.triggers = val.split(/[,，、]/).map((s) => s.trim()).filter(Boolean);
      }
      if (lower.startsWith("描述") || lower.startsWith("description")) {
        const val = line.split(/[:：]/)[1];
        if (val) info.description = val.trim();
      }
      if (lower.startsWith("调用方式") || lower.startsWith("usage") || lower.startsWith("invocation") || lower.startsWith("调用")) {
        const val = line.split(/[:：]/).slice(1).join(":");
        if (val) info.invocation = val.trim();
      }
    }

    if (!info.description && docLines.length > 0) {
      info.description = docLines[0];
    }

    return info;
  } catch (e) {
    D(`parse error for ${filePath}: ${e.message}`);
    return null;
  }
}

function scanWorkflows(workspaceDir) {
  const wfDir = path.join(workspaceDir, "workflows");
  const results = [];
  try {
    const files = fs.readdirSync(wfDir);
    for (const f of files) {
      if (!f.endsWith(".py") || f.startsWith("_") || f.startsWith(".")) continue;
      const fp = path.join(wfDir, f);
      try { if (!fs.statSync(fp).isFile()) continue; } catch { continue; }
      const info = parseWorkflow(fp);
      if (info) results.push(info);
    }
  } catch (e) {
    D(`scan error: ${e.message}`);
  }
  return results;
}

function generateBootstrap(workflows) {
  const lines = [
    "# MODE GATE — 执行模式路由（自动生成，勿删改）",
    "",
    "> **这是你收到用户任务后的第一个判断。在读 skill、写代码、调工具之前，先走完这个路由。**",
    "",
    "## 路由决策",
    "",
    "```",
    "收到用户任务",
    "    │",
  ];

  if (workflows.length) {
    lines.push(
      "    ├─ 匹配下方工作流触发词？",
      "    │   ├─ YES → Mode B（汇报 → 确认 → 执行 .py → 交付）",
      "    │   └─ NO ↓",
    );
  }

  lines.push(
    "    ├─ 简单任务（单步、问答）？",
    "    │   ├─ YES → Mode A（直接执行）",
    "    │   └─ NO ↓",
    "    └─ 复杂任务 → Mode C（汇报 → 确认 → todo 逐步执行）",
    "```",
    "",
  );

  if (workflows.length) {
    lines.push("## 可用工作流（Mode B 路由表）", "");

    for (const wf of workflows) {
      lines.push(`### ${wf.name}`);
      if (wf.triggers.length) lines.push(`- **触发词**：${wf.triggers.join("、")}`);
      if (wf.description) lines.push(`- **描述**：${wf.description}`);
      if (wf.invocation) lines.push(`- **调用**：\`${wf.invocation}\``);
      lines.push("");
    }

    lines.push(
      "## Mode B 执行规则",
      "",
      "1. **汇报**：告诉用户匹配到了哪个工作流，等用户确认",
      "2. **执行**：运行 .py 文件（原子操作，不拆步骤，不建 todo）",
      "3. **交付**：把结果返回给用户",
      "",
      "> **禁止**：匹配到工作流后自己手动读 skill 编排步骤。工作流已经封装好了，你只管调用。",
      "",
    );
  } else {
    lines.push(
      "## 当前无可用工作流",
      "",
      "所有任务走 Mode A 或 Mode C。",
      "",
    );
  }

  return lines.join("\n");
}

const modeGateBootstrapHandler = async (event) => {
  if (event.type !== "agent" || event.action !== "bootstrap") return;

  D("bootstrap FIRED");
  const context = event.context ?? {};
  const workspaceDir = context.workspaceDir || process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");

  const workflows = scanWorkflows(workspaceDir);
  D(`found ${workflows.length} workflows: ${workflows.map((w) => w.name).join(", ") || "none"}`);

  const content = generateBootstrap(workflows);

  const fp = path.join(workspaceDir, "MODE-GATE.md");
  try {
    fs.writeFileSync(fp, content, "utf-8");
    D(`wrote MODE-GATE.md`);
  } catch (e) {
    D(`write err: ${e.message}`);
  }

  const bf = context.bootstrapFiles;
  if (Array.isArray(bf)) {
    const idx = bf.findIndex(
      (f) => f.name === "MODE-GATE.md" || f.path?.endsWith("MODE-GATE.md"),
    );
    if (idx >= 0) bf.splice(idx, 1);

    bf.unshift({
      name: "MODE-GATE.md",
      path: fp,
      content,
      source: "mode-gate",
    });
    D(`injected MODE-GATE.md (${bf.length} total bootstrap files)`);
  } else {
    D("WARNING: bootstrapFiles not found in event.context");
  }
};

export default modeGateBootstrapHandler;
HANDLER_EOF
fi

info "Mode Gate hook installed → $MODE_HOOK_DIR"

# ══════════════════════════════════════════════════════════════
section "3/4  Workflow Engine (skill_runner + lib)"
# ══════════════════════════════════════════════════════════════

WF_DIR="$OC_WORKSPACE/workflows"
LIB_DIR="$WF_DIR/lib"
mkdir -p "$LIB_DIR"
mkdir -p "$WF_DIR/output"

if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/workflow-engine/lib/__init__.py" "$LIB_DIR/__init__.py"
    cp "$SRC_DIR/workflow-engine/lib/skill_runner.py" "$LIB_DIR/skill_runner.py"
else
    touch "$LIB_DIR/__init__.py"
    # skill_runner.py is too large for inline heredoc — download from GitHub
    RUNNER_URL="https://raw.githubusercontent.com/Nimo1987/openclaw-powerpack/main/workflow-engine/lib/skill_runner.py"
    if curl -sL "$RUNNER_URL" -o "$LIB_DIR/skill_runner.py" 2>/dev/null; then
        info "Downloaded skill_runner.py from GitHub"
    else
        error "Failed to download skill_runner.py. Please install from git clone instead."
    fi
fi

info "Workflow engine installed → $LIB_DIR"

# ══════════════════════════════════════════════════════════════
section "4/4  Workflow Builder (Skill)"
# ══════════════════════════════════════════════════════════════

WB_DIR="$OC_WORKSPACE/skills/workflow-builder"
mkdir -p "$WB_DIR"

if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/workflow-engine/skills/workflow-builder/SKILL.md" "$WB_DIR/SKILL.md"
else
    WB_URL="https://raw.githubusercontent.com/Nimo1987/openclaw-powerpack/main/workflow-engine/skills/workflow-builder/SKILL.md"
    if curl -sL "$WB_URL" -o "$WB_DIR/SKILL.md" 2>/dev/null; then
        info "Downloaded workflow-builder SKILL.md from GitHub"
    else
        error "Failed to download SKILL.md. Please install from git clone instead."
    fi
fi

info "Workflow Builder skill installed → $WB_DIR"

# ══════════════════════════════════════════════════════════════
section "Updating openclaw.json"
# ══════════════════════════════════════════════════════════════

OC_CONFIG="$OC_CONFIG" PLUGIN_DIR="$PLUGIN_DIR" python3 << 'PYEOF'
import json, os

config_path = os.environ["OC_CONFIG"]
plugin_dir = os.environ["PLUGIN_DIR"]

with open(config_path, "r") as f:
    cfg = json.load(f)

# Ensure plugins section
for key in ["plugins"]:
    if key not in cfg:
        cfg[key] = {}
for key in ["entries", "installs", "load"]:
    if key not in cfg["plugins"]:
        cfg["plugins"][key] = {}
if "paths" not in cfg["plugins"]["load"]:
    cfg["plugins"]["load"]["paths"] = []

# Step Gate plugin entry
cfg["plugins"]["entries"]["step-gate"] = {
    "enabled": True,
    "config": {
        "enabled": True,
        "minSteps": 3
    }
}

cfg["plugins"]["installs"]["step-gate"] = {
    "source": "path",
    "spec": plugin_dir,
    "sourcePath": plugin_dir,
    "installPath": plugin_dir,
    "version": "11.0.0",
    "resolvedName": "step-gate",
    "resolvedVersion": "11.0.0"
}

if plugin_dir not in cfg["plugins"]["load"]["paths"]:
    cfg["plugins"]["load"]["paths"].append(plugin_dir)

# Enable internal hooks
if "hooks" not in cfg:
    cfg["hooks"] = {}
if "internal" not in cfg["hooks"]:
    cfg["hooks"]["internal"] = {}
cfg["hooks"]["internal"]["enabled"] = True
if "entries" not in cfg["hooks"]["internal"]:
    cfg["hooks"]["internal"]["entries"] = {}
cfg["hooks"]["internal"]["entries"]["step-gate"] = {"enabled": True}
cfg["hooks"]["internal"]["entries"]["mode-gate"] = {"enabled": True}

with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)

print("Config updated successfully")
PYEOF

info "openclaw.json updated"

# ══════════════════════════════════════════════════════════════
section "Restarting Gateway"
# ══════════════════════════════════════════════════════════════

> /tmp/step-gate.log 2>/dev/null || true
> /tmp/mode-gate.log 2>/dev/null || true

if pgrep -f openclaw-gateway > /dev/null 2>&1; then
    kill -15 $(pgrep -f openclaw-gateway) 2>/dev/null
    sleep 3
    for i in $(seq 1 10); do
        if pgrep -f openclaw-gateway > /dev/null 2>&1; then
            info "Gateway restarted (PID: $(pgrep -f openclaw-gateway))"
            break
        fi
        sleep 2
    done
    if ! pgrep -f openclaw-gateway > /dev/null 2>&1; then
        warn "Gateway did not auto-restart. Please start it manually."
    fi
else
    warn "Gateway not running. Please start it manually."
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "OpenClaw PowerPack installed!"
echo ""
echo "  Components:"
echo "    1. Step Gate   → $HOOK_DIR + $PLUGIN_DIR"
echo "    2. Mode Gate   → $MODE_HOOK_DIR"
echo "    3. Skill Runner → $LIB_DIR"
echo "    4. Workflow Builder → $WB_DIR"
echo ""
echo "  Verify:"
echo "    tail -f /tmp/step-gate.log /tmp/mode-gate.log"
echo "    # Start a new session and look for 'bootstrap FIRED'"
echo ""
echo "  Uninstall:"
echo "    rm -rf $HOOK_DIR $PLUGIN_DIR $MODE_HOOK_DIR"
echo "    rm -rf $LIB_DIR $WB_DIR"
echo "    # Then remove step-gate and mode-gate from openclaw.json"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
