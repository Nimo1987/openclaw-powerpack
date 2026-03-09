---
name: workflow-builder
description: (v3.0) 帮助用户将多个 skill 串联成一个确定性工作流（workflow）。自动生成 .py 文件，自检，存入 workflows 目录。
---

# Workflow Builder v3.0.0

## 1. 概述

本 Skill 用于创建新的工作流。工作流是多个 skill 的确定性串联：每个 skill 的输出物作为下一个 skill 的输入物，由 Python 代码控制执行顺序。

**核心原则**：
- 工作流不创造新能力，只编排已有 skill
- 统一调用接口：所有 skill 调用都通过 `run_skill(skill_name, input_data)` 完成
- workflow 不关心 skill 内部实现，skill 出问题是 skill 的问题
- 每步的输出就是下一步的输入，数据以自然语言或文本形式在步骤间流转

---

## 2. 工作流架构

```
~/.openclaw/workspace/workflows/
├── lib/
│   ├── __init__.py
│   └── skill_runner.py          # 通用执行器（已存在，不要修改）
├── image_assistant.py           # 已有工作流示例
├── [new_workflow].py            # 你要创建的新工作流
└── output/                      # 工作流输出物
```

### skill_runner.py 提供的函数

```python
from lib.skill_runner import run_skill, run_llm_raw

# 1. 调用任意 skill（统一接口）
output = run_skill("skill-name", input_data)

# 2. LLM 原生能力（不经过任何 skill）
output = run_llm_raw(system_prompt, user_input)
```

### `run_skill()` 的内部逻辑

workflow 不需要知道这些细节，但创建工作流时需要理解 skill_runner 的能力：

- 检查 skill 目录下是否有 `entry.json`
- **有 entry.json** → 可执行型 skill → 读 entry.json 拼命令，subprocess 执行
- **没有 entry.json** → LLM 行为型 skill → 两步调用：
  1. 读 SKILL.md + MANIFEST 索引 → LLM 选择需要的知识库章节（按需加载，节省 token）
  2. 精确加载选中的 KB 章节 → LLM 生成最终输出
  3. 如果选择失败，自动 fallback 到全量加载知识库

### 什么时候用 `run_skill()` vs `run_llm_raw()`

| 场景 | 用什么 | 示例 |
|:---|:---|:---|
| 需要某个 skill 的专业知识库 | `run_skill("skill-name", data)` | 调 image-prompt-writer 生成专业提示词 |
| 需要某个 skill 的可执行脚本 | `run_skill("skill-name", data)` | 调 nano-banana-pro 生成图片 |
| 只需要 LLM 的通用理解/分析/总结能力 | `run_llm_raw(system_prompt, data)` | 梳理用户需求、格式转换、意图分析 |

**判断标准**：这一步是否需要某个 skill 的 SKILL.md 或脚本？需要 → `run_skill()`，不需要 → `run_llm_raw()`。

### `input_data` 的传递规则

**统一传自然语言或上一步的文本输出。** workflow 不需要关心 skill 内部是什么类型：

- 对于 LLM 行为型 skill：`input_data` 直接作为 user prompt 传给 LLM
- 对于可执行型 skill：`input_data` 如果是 JSON 字符串，skill_runner 自动解析为参数字典；如果是纯文本，自动包装为 `{"prompt": input_data}`

workflow 只需要确保每步的输出能被下一步理解即可。

---

## 3. 创建工作流的步骤

### Step 1: 确认 pipe

跟用户确认：

| 信息 | 说明 |
|:---|:---|
| 工作流名称 | 英文下划线命名，如 `deep_report` |
| 工作流描述 | 一句话说明用途 |
| 触发词 | 用户说什么话时触发此工作流 |
| Pipe 步骤 | 按顺序列出每一步：用 `run_llm_raw` 还是 `run_skill`，调哪个 skill |
| 输入参数 | 用户需要提供什么参数 |
| 输出格式 | 最终输出什么（文件、文本、JSON） |

### Step 2: 检查 skill 可用性

对 pipe 中的每个 skill：
1. 确认 `~/.openclaw/workspace/skills/{skill_name}/SKILL.md` 存在
2. 如果是可执行型 skill（有脚本），确认 `entry.json` 存在。如果不存在，按第 5 节的格式创建
3. 如果某个 skill 不存在，告诉用户需要先安装该 skill，不要自己创造替代品

### Step 3: 生成 .py 文件

按以下模板生成：

```python
#!/usr/bin/env python3
"""
{workflow_name}.py — {中文名称}

触发词：{触发词1}、{触发词2}、{触发词3}
调用：python3 ~/.openclaw/workspace/workflows/{workflow_name}.py --request "用户需求" {其他参数}
参数：
  --request / -r （必填）用户需求
  {其他参数说明}

Pipe: {step1描述} → {step2描述} → ... → 输出
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from lib.skill_runner import run_skill, run_llm_raw


def run_workflow(user_request: str, ...) -> dict:
    """
    纯 pipe：每步的输出作为下一步的输入。
    """

    # ── Step 1/N: 描述这一步做什么 ──
    print("[Step 1/N] 描述...", file=sys.stderr)
    data = run_llm_raw("你的角色是...", user_request)
    # 或者：data = run_skill("skill-name", user_request)
    print("[Step 1/N] 完成。\n", file=sys.stderr)

    # ── Step 2/N: 描述这一步做什么 ──
    print("[Step 2/N] 描述...", file=sys.stderr)
    data = run_skill("skill-name", data)
    print("[Step 2/N] 完成。\n", file=sys.stderr)

    # ── 继续 pipe，直到最后一步 ──

    return {"status": "success", "result": data}


def main():
    parser = argparse.ArgumentParser(description="工作流描述")
    parser.add_argument("--request", "-r", required=True, help="用户需求")
    # 其他参数...
    args = parser.parse_args()

    try:
        result = run_workflow(args.request, ...)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except Exception as e:
        print(json.dumps({"status": "error", "error": str(e)}, ensure_ascii=False, indent=2))
        sys.exit(1)


if __name__ == "__main__":
    main()
```

### Step 4: 自检

生成后执行：
1. **语法检查**：`python3 -c "import ast; ast.parse(open('workflow.py').read())"`
2. **依赖检查**：确认 pipe 中引用的每个 skill 都存在于 `skills/` 目录
3. **docstring 检查**：确认触发词和调用方式完整（这是爪爪识别工作流的唯一依据）

### Step 5: 部署

将 .py 文件保存到 `~/.openclaw/workspace/workflows/`。

---

## 4. entry.json 格式

为可执行型 skill 创建 `entry.json`，保存到 `skills/{skill_name}/entry.json`：

```json
{
  "command": "uv run {baseDir}/scripts/脚本名.py",
  "timeout": 300,
  "params": {
    "参数名": {
      "flag": "--参数flag",
      "required": true,
      "default": "默认值（可选）",
      "description": "参数说明"
    }
  }
}
```

`{baseDir}` 会被 skill_runner 自动替换为 skill 的实际目录路径。

---

## 5. 注意事项

- **不要修改 `lib/skill_runner.py`**，它是所有工作流共用的基础设施
- **不要在工作流中硬编码 API key**，skill_runner 会自动从 openclaw.json 读取
- **每步的输出就是下一步的输入**，保持数据流清晰
- **stderr 用于进度日志，stdout 用于最终结果**（JSON 格式）
- 如果某个 skill 不存在，先告诉用户需要安装该 skill，不要自己创造替代品
- 工作流的 docstring 是爪爪识别和调用工作流的唯一依据，必须写清楚触发词和调用命令
