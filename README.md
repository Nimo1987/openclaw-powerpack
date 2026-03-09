# OpenClaw PowerPack

**给 OpenClaw Agent 装上执行纪律和工作流引擎。**

一键安装 4 个组件，解决 Agent 跳步、不走工作流、手动编排已有 pipe 的问题。

---

## 组件

| 组件 | 类型 | 解决什么问题 |
|---|---|---|
| **Step Gate** | Internal Hook + Plugin | Agent 执行多步任务时跳步、合并步骤、忘记更新进度 |
| **Mode Gate** | Internal Hook | Agent 不知道该走哪种执行模式（直接做 / 调工作流 / 拆步骤） |
| **Skill Runner** | Python 库 | 工作流需要统一接口调用 skill，不关心 skill 内部是 LLM 型还是可执行型 |
| **Workflow Builder** | Skill | Agent 需要自己创建新的工作流，把多个 skill 串成 pipe |

## 架构

```
Agent 收到任务
    │
    ├─ Mode Gate（bootstrap 注入）
    │   判断走哪种模式：
    │   ├─ Mode A：简单任务，直接做
    │   ├─ Mode B：匹配工作流，调 .py 执行
    │   └─ Mode C：复杂任务，拆步骤逐步执行
    │
    ├─ Step Gate（bootstrap 注入 + 定时同步）
    │   Mode C 时强制执行纪律：
    │   ├─ 按顺序执行，不跳步
    │   ├─ 每步完成后更新 Execution Log
    │   └─ 自动同步 checkbox 状态
    │
    └─ Workflow Engine（skill_runner + workflow-builder）
        Mode B 时的执行引擎：
        ├─ run_skill("skill-name", data) → 统一调用任意 skill
        ├─ run_llm_raw(system, user) → 调用 LLM 原生能力
        └─ workflow-builder skill → Agent 自己创建新工作流
```

## 安装

```bash
# 方式一：一键安装
git clone https://github.com/Nimo1987/openclaw-powerpack.git
cd openclaw-powerpack
sudo bash install.sh

# 方式二：curl 安装（skill_runner.py 和 SKILL.md 从 GitHub 下载）
curl -sL https://raw.githubusercontent.com/Nimo1987/openclaw-powerpack/main/install.sh | sudo bash
```

安装脚本会：

1. 部署 Step Gate hook 到 `~/.openclaw/hooks/step-gate/`
2. 部署 Step Gate plugin 到 `~/.openclaw/extensions/step-gate/`
3. 部署 Mode Gate hook 到 `~/.openclaw/hooks/mode-gate/`
4. 部署 skill_runner.py 到 `~/.openclaw/workspace/workflows/lib/`
5. 部署 workflow-builder skill 到 `~/.openclaw/workspace/skills/workflow-builder/`
6. 更新 `openclaw.json`（启用 hooks + plugin）
7. 重启 Gateway

## 前置要求

- OpenClaw 已安装并运行
- Python 3.10+
- `openclaw.json` 中已配置 LLM provider（skill_runner 从中读取 API key 和 model）

## 目录结构

```
openclaw-powerpack/
├── step-gate/
│   └── hook/
│       ├── HOOK.md              # Hook 声明文件
│       └── handler.js           # Bootstrap 注入逻辑
├── mode-gate/
│   └── hook/
│       ├── HOOK.md              # Hook 声明文件
│       └── handler.js           # 工作流扫描 + 路由表生成
├── workflow-engine/
│   ├── lib/
│   │   ├── __init__.py
│   │   └── skill_runner.py      # 统一 skill 调用接口
│   └── skills/
│       └── workflow-builder/
│           └── SKILL.md         # 创建工作流的指导文档
├── install.sh                   # 一键安装脚本
├── LICENSE
└── README.md
```

## 各组件详解

### Step Gate

监听 `agent:bootstrap` 事件，扫描 workspace 中的 `todo*.md` 文件，生成 `STEP-GATE.md` 注入 agent 上下文。

**Hook**：注入步骤纪律和当前进度到 agent 的 bootstrap context。

**Plugin**：每 15 秒扫描 todo 文件，当 Execution Log 中某步标记为 `Status: done` 时，自动将对应的 `[ ]` 改为 `[x]`。

配置项（`openclaw.json` → `plugins.entries.step-gate.config`）：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `true` | 启用/禁用 |
| `minSteps` | `3` | 最少多少步才触发 |
| `syncInterval` | `15000` | checkbox 同步间隔（ms） |

### Mode Gate

监听 `agent:bootstrap` 事件，扫描 `workflows/*.py` 的 docstring，提取触发词和调用方式，生成 `MODE-GATE.md` 路由表注入 agent 上下文。

Agent 每次醒来第一个看到的就是这个路由表，强制它在做任何事之前先判断执行模式。

**工作流 docstring 格式**（Mode Gate 依赖这个格式扫描）：

```python
"""
image_assistant.py — 做图小助手

触发词：做张图、帮我画、生成图片、做个图
描述：接收用户需求，自动生成电商图
调用：python3 workflows/image_assistant.py --request "用户需求"
"""
```

### Skill Runner

所有工作流共用的执行引擎。提供两个函数：

```python
from lib.skill_runner import run_skill, run_llm_raw

# 调用任意 skill（自动判断类型）
output = run_skill("image-prompt-writer", "用户需求描述")

# 调用 LLM 原生能力
output = run_llm_raw("你是一个分析师", "分析这段文本")
```

`run_skill()` 内部逻辑：

- 有 `entry.json` → 可执行型 skill → subprocess 执行
- 只有 `SKILL.md` → LLM 行为型 skill → 两步调用（先选 KB 章节，再生成）

LLM 配置自动从 `openclaw.json` 读取，跟随系统主 LLM。

### Workflow Builder

一个 Skill，让 Agent 能自己创建新的工作流。Agent 读取 `SKILL.md` 后，按照模板生成 `.py` 文件，自检语法和依赖，部署到 `workflows/` 目录。

新工作流部署后，下次 session 启动时 Mode Gate 会自动扫描到它并加入路由表。

## 验证

```bash
# 查看日志
tail -f /tmp/step-gate.log /tmp/mode-gate.log

# 在 Telegram 发 /new 开新 session，应该看到：
# [mode-gate] bootstrap FIRED
# [mode-gate] found N workflows: image_assistant, ...
# [mode-gate] injected MODE-GATE.md (X total bootstrap files)
# [hook] bootstrap FIRED
# [hook] found N todos (M completed)

# 检查生成的文件
cat ~/.openclaw/workspace/MODE-GATE.md
cat ~/.openclaw/workspace/STEP-GATE.md
```

## 卸载

```bash
# 删除文件
rm -rf ~/.openclaw/hooks/step-gate
rm -rf ~/.openclaw/hooks/mode-gate
rm -rf ~/.openclaw/extensions/step-gate
rm -rf ~/.openclaw/workspace/workflows/lib
rm -rf ~/.openclaw/workspace/skills/workflow-builder

# 从 openclaw.json 中移除 step-gate 和 mode-gate 相关配置
```

## 版本历史

| 版本 | 变化 |
|---|---|
| Step Gate v1-v10 | 探索阶段。用错了 hook 系统，bootstrap 注入从未生效 |
| Step Gate v11 | 拆分为 Internal Hook + Plugin，bootstrap 注入终于用对了系统 |
| Mode Gate v1 | 首版。扫描 workflows/ 生成路由表，解决 Agent 不走工作流的问题 |
| Skill Runner v1 | 首版。统一 skill 调用接口，支持 LLM 型和可执行型 |
| Workflow Builder v3 | 首版打包发布。Agent 自主创建工作流 |

## License

MIT
