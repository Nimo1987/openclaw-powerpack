#!/usr/bin/env python3
"""
skill_runner.py — 通用 Skill 执行器

所有 workflow 共用。workflow 只需调用:
    run_skill(skill_name, input_data) -> str

skill_runner 内部自动判断 skill 类型并执行：
- 有 entry.json → 可执行型 skill，subprocess 调用
- 只有 SKILL.md → LLM 行为型 skill，读 SKILL.md 喂给系统主 LLM

系统主 LLM 配置从 openclaw.json 自动读取，不写死。
"""

import json
import os
import subprocess
import sys
import urllib.request
import urllib.error
from pathlib import Path

# ============================================================
# 路径常量
# ============================================================

OPENCLAW_DIR = Path("/root/.openclaw")
CONFIG_FILE = OPENCLAW_DIR / "openclaw.json"
WORKSPACE_DIR = OPENCLAW_DIR / "workspace"
SKILLS_DIR = WORKSPACE_DIR / "skills"
WORKFLOWS_DIR = WORKSPACE_DIR / "workflows"
OUTPUT_DIR = WORKFLOWS_DIR / "output"

# ============================================================
# LLM 配置（从 openclaw.json 读取，跟随系统主 LLM）
# ============================================================

_llm_config_cache = None

def get_llm_config() -> dict:
    """从 openclaw.json 读取主 LLM 配置
    
    配置结构：
      agents.defaults.model.primary = "moonshot/kimi-k2.5"
      models.providers.moonshot.apiKey = "sk-..."
      models.providers.moonshot.baseUrl = "https://api.moonshot.ai/v1"
    """
    global _llm_config_cache
    if _llm_config_cache:
        return _llm_config_cache

    with open(CONFIG_FILE, "r") as f:
        config = json.load(f)

    # 从 agents.defaults.model.primary 读取主模型 ID
    model_id = (config.get("agents", {})
                      .get("defaults", {})
                      .get("model", {})
                      .get("primary", ""))

    # 解析 provider/model 格式，如 "moonshot/kimi-k2.5"
    if "/" in model_id:
        provider, model_name = model_id.split("/", 1)
    else:
        provider, model_name = "", model_id

    # 从 models.providers.{provider} 读取 apiKey 和 baseUrl
    provider_config = (config.get("models", {})
                             .get("providers", {})
                             .get(provider, {}))
    api_key = provider_config.get("apiKey", "")
    base_url = provider_config.get("baseUrl", "")

    # fallback：如果 provider 配置里没有 baseUrl，用默认值
    if not base_url:
        provider_urls = {
            "moonshot": "https://api.moonshot.ai/v1",
            "openai": "https://api.openai.com/v1",
            "anthropic": "https://api.anthropic.com/v1",
            "deepseek": "https://api.deepseek.com/v1",
        }
        base_url = provider_urls.get(provider, "https://api.openai.com/v1")

    _llm_config_cache = {
        "provider": provider,
        "model": model_name,
        "api_key": api_key,
        "base_url": base_url,
    }
    return _llm_config_cache


# ============================================================
# LLM 调用
# ============================================================

def call_llm(system_prompt: str, user_input: str, model: str = None,
             max_tokens: int = 4096) -> str:
    """调用系统主 LLM（OpenAI 兼容 API）

    不发送 temperature 参数，因为部分模型（如 Kimi K2.5）只允许固定值。
    """
    llm = get_llm_config()
    base_url = llm["base_url"].rstrip("/")
    api_key = llm["api_key"]
    use_model = model or llm["model"]

    payload = {
        "model": use_model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_input},
        ],
        "max_tokens": max_tokens,
    }

    req = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"LLM API error {e.code}: {body}") from e

    return result["choices"][0]["message"]["content"]


# ============================================================
# Skill 类型判断与加载
# ============================================================

def _get_skill_type(skill_name: str) -> str:
    """判断 skill 类型：'exec' 或 'llm'"""
    skill_dir = SKILLS_DIR / skill_name
    entry_file = skill_dir / "entry.json"
    if entry_file.exists():
        return "exec"
    return "llm"


def _load_skill_md(skill_name: str) -> str:
    """读取 skill 的 SKILL.md 内容"""
    skill_dir = SKILLS_DIR / skill_name
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.exists():
        raise FileNotFoundError(f"SKILL.md not found: {skill_md}")
    return skill_md.read_text(encoding="utf-8")


def _load_entry(skill_name: str) -> dict:
    """读取可执行 skill 的 entry.json"""
    skill_dir = SKILLS_DIR / skill_name
    entry_file = skill_dir / "entry.json"
    with open(entry_file, "r") as f:
        return json.load(f)


# ============================================================
# 执行：LLM 行为型 skill
# ============================================================

def _find_manifest(skill_name: str) -> Path | None:
    """查找 skill 的 MANIFEST.json 文件"""
    refs_dir = SKILLS_DIR / skill_name / "references"
    if not refs_dir.exists():
        return None
    for name in ["KB_MASTER_MANIFEST.json", "MANIFEST.json", "manifest.json"]:
        p = refs_dir / name
        if p.exists():
            return p
    return None


def _load_file_lines(file_path: Path, start: int, end: int) -> str:
    """按行号精确读取文件内容（1-indexed, inclusive）"""
    lines = file_path.read_text(encoding="utf-8").splitlines()
    # 转为 0-indexed
    s = max(0, start - 1)
    e = min(len(lines), end)
    return "\n".join(lines[s:e])


def _resolve_kb_path(skill_name: str, manifest_path: str) -> Path:
    """将 MANIFEST 中的 file_path 解析为服务器上的实际路径
    
    MANIFEST 中的路径可能是旧路径（如 /home/ubuntu/skills/...），
    需要映射到实际的 skill references 目录。
    """
    refs_dir = SKILLS_DIR / skill_name / "references"
    # 取文件名部分
    filename = Path(manifest_path).name
    actual = refs_dir / filename
    if actual.exists():
        return actual
    # fallback: 尝试原始路径
    orig = Path(manifest_path)
    if orig.exists():
        return orig
    raise FileNotFoundError(f"KB file not found: {filename} (tried {actual} and {orig})")


def _step1_select(skill_md: str, manifest_json: str, user_input: str) -> dict | None:
    """第一步 LLM 调用：根据 SKILL.md 和 MANIFEST 索引，选择需要加载的 KB 章节
    
    返回 JSON dict，包含 sections 列表。解析失败返回 None（触发 fallback）。
    """
    system_prompt = (
        skill_md
        + "\n\n"
        + "=" * 60
        + "\n以下是知识库的目录索引（MANIFEST），包含所有可用的 KB 文件和章节。\n"
        + "你不需要读取任何文件，只需要根据用户需求，从索引中选择你需要的章节。\n"
        + "=" * 60
        + "\n" + manifest_json
    )

    select_instruction = (
        "根据以下用户需求，从 MANIFEST 索引中选择你完成任务所需的 KB 章节。\n"
        "你必须严格输出以下 JSON 格式，不要输出任何其他内容：\n"
        '```json\n'
        '{\n'
        '  "sections": [\n'
        '    {"file": "KB_文件名.md", "title": "章节标题", "start_line": 起始行, "end_line": 结束行},\n'
        '    ...\n'
        '  ]\n'
        '}\n'
        '```\n\n'
        "选择原则：\n"
        "- 选择与用户需求最相关的风格章节（通常 1-2 个）\n"
        "- 必须选择相关的技术参数章节（构图、光影、色彩、相机）\n"
        "- file 和 title 必须与 MANIFEST 中完全一致\n"
        "- start_line 和 end_line 必须与 MANIFEST 中完全一致\n\n"
        f"用户需求：{user_input}"
    )

    try:
        response = call_llm(system_prompt, select_instruction, max_tokens=2048)
        # 提取 JSON
        if "```json" in response:
            json_str = response.split("```json")[1].split("```")[0].strip()
        elif "```" in response:
            json_str = response.split("```")[1].split("```")[0].strip()
        else:
            json_str = response.strip()
        result = json.loads(json_str)
        if "sections" in result and len(result["sections"]) > 0:
            return result
    except Exception as e:
        print(f"[skill_runner] Step 1 select failed: {e}", file=sys.stderr)
    return None


def _step2_generate(skill_md: str, kb_content: str, user_input: str) -> str:
    """第二步 LLM 调用：用选中的 KB 内容生成最终输出"""
    system_prompt = (
        skill_md
        + "\n\n"
        + "=" * 60
        + "\n以下是与本次任务相关的知识库内容，你可以直接引用，不需要执行任何文件读取操作。\n"
        + "=" * 60
        + "\n" + kb_content
    )
    return call_llm(system_prompt, user_input, max_tokens=8192)


def _load_all_references(skill_name: str) -> str:
    """全量加载 references/ 目录（fallback 用）"""
    refs_dir = SKILLS_DIR / skill_name / "references"
    if not refs_dir.exists():
        return ""
    kb_parts = []
    for f in sorted(refs_dir.iterdir()):
        if f.is_file() and not f.name.endswith(".json"):  # 跳过 MANIFEST.json
            try:
                content = f.read_text(encoding="utf-8")
                kb_parts.append(f"\n\n{'='*60}\nFILE: {f.name}\n{'='*60}\n{content}")
            except Exception:
                pass
    return "".join(kb_parts)


def _run_llm_skill(skill_name: str, input_data: str) -> str:
    """
    执行 LLM 行为型 skill（两步调用：先选后加载）。

    有 MANIFEST 时：
      Step 1: SKILL.md + MANIFEST 索引 → LLM 选择需要的 KB 章节
      Step 2: SKILL.md + 选中的 KB 内容 → LLM 生成最终输出
    
    无 MANIFEST 或 Step 1 失败时：
      Fallback: SKILL.md + 全量知识库 → LLM 生成（保证不丢失功能）
    """
    skill_md = _load_skill_md(skill_name)
    manifest_path = _find_manifest(skill_name)

    # 没有 MANIFEST → 直接全量加载
    if not manifest_path:
        print(f"[skill_runner] No MANIFEST found, using full load", file=sys.stderr)
        kb_content = _load_all_references(skill_name)
        if kb_content:
            system_prompt = (
                skill_md + "\n\n" + "=" * 60
                + "\n以下是知识库文件的完整内容，你可以直接引用。\n"
                + "=" * 60 + kb_content
            )
        else:
            system_prompt = skill_md
        return call_llm(system_prompt, input_data, max_tokens=8192)

    # 有 MANIFEST → 两步调用
    manifest_json = manifest_path.read_text(encoding="utf-8")
    print(f"[skill_runner] Step 1: selecting KB sections...", file=sys.stderr)

    selection = _step1_select(skill_md, manifest_json, input_data)

    if selection is None:
        # Step 1 失败 → fallback 全量加载
        print(f"[skill_runner] Step 1 failed, fallback to full load", file=sys.stderr)
        kb_content = _load_all_references(skill_name)
        system_prompt = (
            skill_md + "\n\n" + "=" * 60
            + "\n以下是知识库文件的完整内容，你可以直接引用。\n"
            + "=" * 60 + kb_content
        )
        return call_llm(system_prompt, input_data, max_tokens=8192)

    # Step 1 成功 → 精确加载选中的章节
    print(f"[skill_runner] Step 1 selected {len(selection['sections'])} sections",
          file=sys.stderr)
    
    kb_parts = []
    for sec in selection["sections"]:
        try:
            file_path = _resolve_kb_path(skill_name, sec["file"])
            content = _load_file_lines(file_path, sec["start_line"], sec["end_line"])
            kb_parts.append(
                f"\n{'='*60}\n"
                f"FILE: {sec['file']} | SECTION: {sec['title']}\n"
                f"{'='*60}\n{content}"
            )
            print(f"  Loaded: {sec['file']} [{sec['start_line']}-{sec['end_line']}] {sec['title']}",
                  file=sys.stderr)
        except Exception as e:
            print(f"  Failed to load {sec.get('file','?')}: {e}", file=sys.stderr)

    if not kb_parts:
        # 所有章节加载失败 → fallback
        print(f"[skill_runner] All sections failed, fallback to full load", file=sys.stderr)
        kb_content = _load_all_references(skill_name)
        system_prompt = (
            skill_md + "\n\n" + "=" * 60
            + "\n以下是知识库文件的完整内容，你可以直接引用。\n"
            + "=" * 60 + kb_content
        )
        return call_llm(system_prompt, input_data, max_tokens=8192)

    kb_content = "".join(kb_parts)
    print(f"[skill_runner] Step 2: generating with {len(kb_content)} chars of KB...",
          file=sys.stderr)
    return _step2_generate(skill_md, kb_content, input_data)


# ============================================================
# 执行：可执行型 skill
# ============================================================

def _run_exec_skill(skill_name: str, input_data: str) -> str:
    """
    执行可执行型 skill。
    读 entry.json 获取命令模板和参数映射，
    把 input_data（JSON 字符串）解析为参数字典，拼命令执行。
    """
    entry = _load_entry(skill_name)
    skill_dir = SKILLS_DIR / skill_name

    # 解析 input_data 为参数字典
    try:
        params = json.loads(input_data)
    except (json.JSONDecodeError, TypeError):
        params = {"prompt": input_data}

    # 构建命令
    command_template = entry["command"]
    # 替换 {baseDir}
    command_template = command_template.replace("{baseDir}", str(skill_dir))

    cmd_parts = command_template.split()

    # 拼接参数
    param_defs = entry.get("params", {})
    for param_name, param_def in param_defs.items():
        value = params.get(param_name, param_def.get("default"))
        if value is None:
            if param_def.get("required", False):
                raise ValueError(f"Missing required param: {param_name}")
            continue

        flag = param_def["flag"]

        # 支持多值参数（如 -i img1 -i img2）
        if isinstance(value, list):
            for v in value:
                cmd_parts.extend([flag, str(v)])
        else:
            cmd_parts.extend([flag, str(value)])

    # 设置 PATH 环境变量
    env = os.environ.copy()
    env["PATH"] = "/root/.local/bin:/root/.local/share/pnpm:/root/.nvm/versions/node/v22.22.0/bin:" + env.get("PATH", "/usr/local/bin:/usr/bin:/bin")

    timeout = entry.get("timeout", 300)

    result = subprocess.run(
        cmd_parts,
        capture_output=True,
        text=True,
        timeout=timeout,
        cwd=str(skill_dir),
        env=env,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Skill '{skill_name}' failed (exit {result.returncode}):\n"
            f"STDERR: {result.stderr.strip()}\n"
            f"STDOUT: {result.stdout.strip()}"
        )

    return result.stdout.strip()


# ============================================================
# 统一接口
# ============================================================

def run_skill(skill_name: str, input_data: str) -> str:
    """
    统一的 skill 调用接口。

    workflow 只需要调这一个函数：
        output = run_skill("image-prompt-writer", input_data)

    内部自动判断 skill 类型并执行。
    """
    skill_type = _get_skill_type(skill_name)

    if skill_type == "exec":
        return _run_exec_skill(skill_name, input_data)
    else:
        return _run_llm_skill(skill_name, input_data)


def run_llm_raw(system_prompt: str, user_input: str) -> str:
    """
    直接调用 LLM 原生能力（不经过 skill）。
    用于 workflow 中需要 LLM 做通用理解/分析的步骤。
    """
    return call_llm(system_prompt, user_input)
