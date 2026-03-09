# OpenClaw PowerPack

> **给 OpenClaw Agent 装上执行纪律和工作流引擎。**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![OpenClaw](https://img.shields.io/badge/Built%20for-OpenClaw-blue)](https://github.com/openclaw/openclaw)

**问题**：OpenClaw Agent 执行多步任务时容易跳步、不走工作流、忘记更新进度。

**解决**：一键安装 4 个组件，让 Agent 拥有执行纪律、自动路由、统一工作流调用能力。

---

## ✨ 效果对比

| 场景 | 原生 OpenClaw | 装 PowerPack 后 |
|------|---------------|-----------------|
| **生成电商图** | 手动调 3 个 skill，容易漏步骤 | 一句话自动走完 pipeline |
| **做复杂报告** | 容易跳步/忘记检查点 | Step Gate 强制执行纪律 |
| **创建新工作流** | 手写 YAML/Python | 对话即可生成工作流 |
| **调试工作流** | 看日志找问题 | 标准 Python traceback |

---

## 🚀 快速开始

```bash
# 一键安装
git clone https://github.com/Nimo1987/openclaw-powerpack.git
cd openclaw-powerpack
sudo bash install.sh

# 测试：让 Agent 帮你画张图
# 在 Telegram/Discord 里对你的 Agent 说：
# "帮我画一只赛博朋克风格的猫"
```

安装后，Agent 会自动：
1. 识别这是"做图"需求 → 走 Mode B（工作流模式）
2. 调用 `image_assistant.py` → 自动生成提示词 + 出图
3. 每步都有记录 → 失败可重试

---

## 📦 包含组件

| 组件 | 类型 | 解决什么问题 |
|---|---|---|
| **Step Gate** | Internal Hook + Plugin | Agent 跳步、合并步骤、忘记更新进度 |
| **Mode Gate** | Internal Hook | Agent 不知道该走哪种执行模式 |
| **Skill Runner** | Python 库 | 统一接口调用任意 skill |
| **Workflow Builder** | Skill | 对话生成新工作流 |

---

## 🏗️ 架构

```
Agent 收到任务
    │
    ├─ Mode Gate（bootstrap 注入）
    │   判断执行模式：
    │   ├─ Mode A：简单任务，直接做
    │   ├─ Mode B：匹配工作流，调 .py 执行 ← 你的 image_assistant 在这里
    │   └─ Mode C：复杂任务，拆步骤逐步执行
    │
    ├─ Step Gate（强制执行纪律）
    │   Mode C 时：
    │   ├─ 按顺序执行，不跳步
    │   ├─ 每步完成后更新 Execution Log
    │   └─ 自动同步 checkbox 状态
    │
    └─ Workflow Engine
        ├─ run_skill("skill-name", data)
        ├─ run_llm_raw(system, user)
        └─ workflow-builder skill
```

---

## 📂 目录结构

```
openclaw-powerpack/
├── step-gate/           # 执行纪律组件
├── mode-gate/           # 路由决策组件
├── workflow-engine/     # 工作流引擎
│   ├── lib/skill_runner.py
│   └── skills/workflow-builder/
├── examples/            # 示例工作流 ⭐ 新增
│   ├── image-assistant/
│   └── report-generator/
├── install.sh           # 一键安装
├── LICENSE
└── README.md
```

---

## 🎯 示例工作流

### 示例 1：AI 电商图生成（image_assistant）

```bash
# 手动调用
python3 examples/image-assistant/workflow.py \
  --request "Bonne Mine 美白精华，泰国风格，9:16" \
  --resolution 2K

# Agent 会自动走这个流程
```

**Pipeline**：
1. LLM 解析需求 → 结构化描述
2. image-prompt-writer → 生成专业提示词
3. nano-banana-pro → 出图

### 示例 2：报告生成器（report_generator）

见 `examples/report-generator/`

---

## ⚙️ 配置

编辑 `~/.openclaw/openclaw.json`：

```json
{
  "plugins": {
    "entries": {
      "step-gate": {
        "enabled": true,
        "config": {
          "minSteps": 3,
          "syncInterval": 15000
        }
      }
    }
  }
}
```

---

## 🎯 长期目标

**在 OpenClaw 生态上，搭建一个可视化工作流无限画布形态**，供每一个 Agent 和人调用，封装成自动化工作流节点，实现管线的自动化生产流程。

> 从命令式 Python 到声明式画布，让工作流编排像画流程图一样简单。

---

## 🤝 联系

**我是技术小白，正在学习！**

如果你是大神，欢迎：
- 🐛 提 Issue 指出问题
- 💡 给建议教我改进  
- 🔧 提 PR 一起完善

**微信**：nimoge1987

---

## 📝 License

MIT © Jiaqi

---

## ⭐ 支持

如果这个项目对你有帮助，请给个 Star！

你的支持是我持续学习和改进的动力。

[![Star History Chart](https://api.star-history.com/svg?repos=Nimo1987/openclaw-powerpack&type=Date)](https://star-history.com/#Nimo1987/openclaw-powerpack&Date)
