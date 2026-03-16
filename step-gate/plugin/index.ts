import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

/**
 * Step Gate Plugin v12 — Checkbox Sync + Auto-Cleanup
 *
 * v12 changes (over v11):
 *   - ADDED: Last-step-done detection — if the highest-numbered step is done,
 *     the task is considered finished regardless of intermediate steps
 *   - ADDED: Stale task timeout — if no step status changes for `staleHours`
 *     (default 6h), the task is auto-completed
 *   - ADDED: Auto-archive — completed tasks are moved to workspace/archive/
 *   - FIXED: Zombie STEP-GATE.md that keeps nagging the agent about
 *     abandoned/skipped tasks
 */

// ── Debug Logger ──────────────────────────────────────────────────────────

const DEBUG_LOG = process.env.STEP_GATE_LOG || "/tmp/step-gate.log";

function D(msg: string): void {
  try {
    fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] [plugin] ${msg}\n`);
  } catch {}
}

// ── Types ─────────────────────────────────────────────────────────────────

interface Step {
  number: number;
  title: string;
  status: "done" | "pending" | "in-progress";
}

interface Todo {
  path: string;
  filename: string;
  steps: Step[];
  total: number;
  done: number;
  current: number | null;
  skipped: number[];
  fileCompleted: boolean;
}

// ── Parser ────────────────────────────────────────────────────────────────

function parseSteps(content: string): Step[] {
  const steps: Step[] = [];
  const lines = content.split("\n");

  const cbRe =
    /^[\s]*[-*]\s*\[([ xX~])\]\s*(?:Step\s*)?(\d+)(?:\s*[-–]\s*(\d+))?[.:]\s*(.*)/i;

  for (const line of lines) {
    const cb = line.match(cbRe);
    if (!cb) continue;
    const mark = cb[1];
    const start = +cb[2];
    const end = cb[3] ? +cb[3] : start;
    const title = cb[4].trim();
    const status: Step["status"] =
      mark === "x" || mark === "X"
        ? "done"
        : mark === "~"
          ? "in-progress"
          : "pending";
    for (let n = start; n <= end; n++) {
      if (!steps.find((x) => x.number === n)) {
        steps.push({ number: n, title, status });
      }
    }
  }

  // Override from Execution Log
  const logIdx = content.indexOf("## Execution Log");
  if (logIdx !== -1) {
    const log = content.slice(logIdx);
    const blockRe =
      /###\s*Step\s*(\d+)[\s\S]*?(?=###\s*Step|\n## |\n$)/gi;
    let m;
    while ((m = blockRe.exec(log)) !== null) {
      const stepNum = +m[1];
      const block = m[0].toLowerCase();
      if (
        block.includes("status: done") ||
        block.includes("status: completed") ||
        block.includes("status: 完成")
      ) {
        const st = steps.find((x) => x.number === stepNum);
        if (st) st.status = "done";
      }
    }
  }

  return steps;
}

// ── File-level completion check ───────────────────────────────────────────

function isFileCompleted(content: string): boolean {
  const header = content.split("\n").slice(0, 10).join("\n").toLowerCase();
  return (
    header.includes("status: completed") ||
    header.includes("status: done") ||
    header.includes("status: 已完成")
  );
}

// ── v12: Check if task is effectively finished ────────────────────────────

function isEffectivelyDone(steps: Step[]): boolean {
  if (!steps.length) return false;
  // All steps done — obvious case
  if (steps.every((s) => s.status === "done")) return true;
  // Last step done — agent skipped ahead and delivered
  const maxStep = steps.reduce((a, b) => (a.number > b.number ? a : b));
  if (maxStep.status === "done") return true;
  return false;
}

// ── v12: Check if task is stale (no progress for N hours) ─────────────────

function isStale(fp: string, staleMs: number): boolean {
  try {
    const stat = fs.statSync(fp);
    return Date.now() - stat.mtimeMs > staleMs;
  } catch {
    return false;
  }
}

// ── v12: Mark file as completed and archive ───────────────────────────────

function markCompleted(fp: string, reason: string): void {
  try {
    let content = fs.readFileSync(fp, "utf-8");
    if (/# Status: In Progress/i.test(content)) {
      content = content.replace(
        /# Status: In Progress/i,
        `# Status: Completed (auto: ${reason})`,
      );
      fs.writeFileSync(fp, content, "utf-8");
    }
    D(`auto-completed: ${path.basename(fp)} reason=${reason}`);
  } catch (e: any) {
    D(`markCompleted err: ${e.message}`);
  }
}

function archiveFile(fp: string, wsDir: string): void {
  try {
    const archiveDir = path.join(wsDir, "archive");
    if (!fs.existsSync(archiveDir)) {
      fs.mkdirSync(archiveDir, { recursive: true });
    }
    const dest = path.join(archiveDir, path.basename(fp));
    fs.renameSync(fp, dest);
    D(`archived: ${path.basename(fp)} -> archive/`);
  } catch (e: any) {
    D(`archive err: ${e.message}`);
  }
}

// ── Analyze a single todo file ────────────────────────────────────────────

function analyze(fp: string): Todo | null {
  try {
    const content = fs.readFileSync(fp, "utf-8");
    const steps = parseSteps(content);
    if (!steps.length) return null;

    const done = steps.filter((s) => s.status === "done").length;
    const sorted = [...steps].sort((a, b) => a.number - b.number);
    const fileCompleted = isFileCompleted(content);

    let current: number | null = null;
    for (const s of sorted) {
      if (s.status !== "done") {
        current = s.number;
        break;
      }
    }

    const skipped: number[] = [];
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

    return {
      path: fp,
      filename: path.basename(fp),
      steps,
      total: steps.length,
      done,
      current,
      skipped,
      fileCompleted,
    };
  } catch {
    return null;
  }
}

// ── Find todo files ───────────────────────────────────────────────────────

function scanDir(dir: string, results: Todo[]): void {
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.startsWith("todo") || !f.endsWith(".md")) continue;
      const fp = path.join(dir, f);
      try {
        if (Date.now() - fs.statSync(fp).mtimeMs > 86400000) continue;
      } catch {
        continue;
      }
      if (results.find((r) => r.path === fp)) continue;
      const t = analyze(fp);
      if (t) results.push(t);
    }
  } catch {}
}

function findTodos(dir: string): Todo[] {
  const results: Todo[] = [];
  scanDir(dir, results);
  scanDir(path.join(dir, "todos"), results);

  return results.sort((a, b) => {
    try {
      return fs.statSync(b.path).mtimeMs - fs.statSync(a.path).mtimeMs;
    } catch {
      return 0;
    }
  });
}

// ── Checkbox Sync ─────────────────────────────────────────────────────────

function syncCheckboxes(fp: string, steps: Step[]): boolean {
  try {
    let content = fs.readFileSync(fp, "utf-8");
    let changed = false;

    for (const s of steps) {
      if (s.status !== "done") continue;

      const patterns = [
        new RegExp(`(- \\[) (\\]\\s*${s.number}\\.\\s*)`, "m"),
        new RegExp(`(- \\[) (\\]\\s*Step\\s*${s.number}[.:]\\s*)`, "mi"),
        new RegExp(
          `(- \\[) (\\]\\s*Step\\s*${s.number}\\s*[-–]\\s*\\d+[.:]\\s*)`,
          "mi",
        ),
      ];

      for (const p of patterns) {
        if (p.test(content)) {
          content = content.replace(p, "$1x$2");
          changed = true;
          D(`cb:${s.number}`);
          break;
        }
      }
    }

    if (
      steps.length &&
      steps.every((s) => s.status === "done") &&
      /# Status: In Progress/i.test(content)
    ) {
      content = content.replace(
        /# Status: In Progress/i,
        "# Status: Completed",
      );
      changed = true;
    }

    if (changed) fs.writeFileSync(fp, content, "utf-8");
    return changed;
  } catch {
    return false;
  }
}

// ── Generate STEP-GATE.md content ─────────────────────────────────────────

function generateBootstrap(todos: Todo[], minSteps: number): string | null {
  const active = todos.filter(
    (t) => !t.fileCompleted && t.total >= minSteps && t.done < t.total,
  );
  if (!active.length) return null;

  const lines: string[] = [
    "# STEP GATE — Task Execution Discipline",
    "",
    "## Rules",
    "",
    "1. Execute steps **in order**. Do NOT skip.",
    "2. Do NOT merge multiple steps into one.",
    "3. After completing each step, update the Execution Log with `Status: done` and a brief Result.",
    "",
  ];

  for (const t of active) {
    lines.push(`## ${t.filename} (${t.done}/${t.total})`, "");

    for (const s of t.steps.sort((a, b) => a.number - b.number)) {
      const icon = s.status === "done" ? "✅" : "⬜";
      const marker = s.number === t.current ? " **← NOW**" : "";
      lines.push(`${icon} Step ${s.number}: ${s.title}${marker}`);
    }
    lines.push("");

    if (t.skipped.length) {
      lines.push(`⚠️ SKIPPED: ${t.skipped.join(", ")}`, "");
    }
    if (t.current) {
      lines.push(`**→ Execute Step ${t.current} now.**`, "");
    }
  }

  return lines.join("\n");
}

// ── Periodic Sync ─────────────────────────────────────────────────────────

function syncAll(dir: string, minSteps: number, staleMs: number): void {
  const todos = findTodos(dir);

  for (const t of todos) {
    // v12: Auto-complete if last step is done (agent skipped ahead)
    if (!t.fileCompleted && isEffectivelyDone(t.steps)) {
      const allDone = t.steps.every((s) => s.status === "done");
      const reason = allDone ? "all-steps-done" : "last-step-done";
      markCompleted(t.path, reason);
      archiveFile(t.path, dir);
      continue; // skip further processing, it's done
    }

    // v12: Auto-complete if stale (no mtime change for staleHours)
    if (!t.fileCompleted && t.done > 0 && isStale(t.path, staleMs)) {
      markCompleted(t.path, `stale-${Math.round(staleMs / 3600000)}h`);
      archiveFile(t.path, dir);
      continue;
    }

    syncCheckboxes(t.path, t.steps);
  }

  // Re-scan after cleanup to generate accurate STEP-GATE.md
  const remaining = findTodos(dir);
  const content = generateBootstrap(remaining, minSteps);
  if (content) {
    try {
      fs.writeFileSync(path.join(dir, "STEP-GATE.md"), content, "utf-8");
    } catch {}
  } else {
    try {
      fs.unlinkSync(path.join(dir, "STEP-GATE.md"));
    } catch {}
  }
}

// ── Plugin Entry Point ────────────────────────────────────────────────────

export default function register(api: any) {
  const cfg = api.pluginConfig ?? {};
  const enabled = cfg.enabled !== false;
  const minSteps = cfg.minSteps ?? 3;
  const syncInterval = cfg.syncInterval ?? 15000;
  const staleHours = cfg.staleHours ?? 6;
  const staleMs = staleHours * 3600000;

  D(`=== step-gate v12 register() ===`);
  D(`config: minSteps=${minSteps} syncInterval=${syncInterval} staleHours=${staleHours}`);
  if (!enabled) return;

  const wsDir = (): string =>
    process.env.OPENCLAW_WORKSPACE_DIR ||
    path.join(os.homedir(), ".openclaw", "workspace");

  // Periodic checkbox sync + auto-cleanup
  setInterval(() => {
    try {
      syncAll(wsDir(), minSteps, staleMs);
    } catch (e: any) {
      D(`sync err: ${e.message}`);
    }
  }, syncInterval);

  D("v12 loaded (checkbox-sync + auto-cleanup, bootstrap via Internal Hook)");
  api.logger?.info?.("step-gate v12 loaded");
}
