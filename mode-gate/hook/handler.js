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

// ── Debug Logger ──────────────────────────────────────────────────────────

const DEBUG_LOG = process.env.MODE_GATE_LOG || "/tmp/mode-gate.log";

function D(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [mode-gate] ${msg}\n`);
  } catch {}
}

// ── Docstring Parser ──────────────────────────────────────────────────────

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
      if (lower.startsWith("调用方式") || lower.startsWith("usage") || lower.startsWith("invocation")) {
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

// ── Scan workflows directory ──────────────────────────────────────────────

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

// ── Generate MODE-GATE.md content ─────────────────────────────────────────

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

// ── Bootstrap Handler ─────────────────────────────────────────────────────

const modeGateBootstrapHandler = async (event) => {
  if (event.type !== "agent" || event.action !== "bootstrap") return;

  D("bootstrap FIRED");
  const context = event.context ?? {};
  const workspaceDir = context.workspaceDir || process.env.OPENCLAW_WORKSPACE_DIR || path.join(os.homedir(), ".openclaw", "workspace");

  const workflows = scanWorkflows(workspaceDir);
  D(`found ${workflows.length} workflows: ${workflows.map((w) => w.name).join(", ") || "none"}`);

  const content = generateBootstrap(workflows);

  // Write MODE-GATE.md to disk
  const fp = path.join(workspaceDir, "MODE-GATE.md");
  try {
    fs.writeFileSync(fp, content, "utf-8");
    D(`wrote MODE-GATE.md`);
  } catch (e) {
    D(`write err: ${e.message}`);
  }

  // Inject into bootstrapFiles
  const bf = context.bootstrapFiles;
  if (Array.isArray(bf)) {
    const idx = bf.findIndex(
      (f) => f.name === "MODE-GATE.md" || f.path?.endsWith("MODE-GATE.md"),
    );
    if (idx >= 0) bf.splice(idx, 1);

    // Prepend — agent sees this first
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
