# 面向大一学生的游戏 AI Agent 汇报 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一份可用 XeLaTeX 编译、适合十分钟课堂讲解的中文游戏 AI Agent 幻灯片源文件。

**Architecture:** 建立独立的 `ctexbeamer` 文件，不触及现有技术论文。用统一的“脉冲竞技场”对战例子组织九页叙事；所有视觉元素由内联 TikZ 图与表格构成，使源文件可移植、易复用。

**Tech Stack:** XeLaTeX、`ctexbeamer`、TikZ/PGF、`booktabs`。

## Global Constraints

- 目标受众是无 AI 基础的大一学生；不用公式、代码或神经网络细节。
- 幻灯片为中文、16:9、共 9 页（含封面），每页只有一个中心结论。
- 必须以“为何需要 Agent、无 Agent 如何设计与人博弈、传统方案的问题”为主要叙事。
- 图示只用 TikZ；不依赖外部图片、网络资源或现有 `docs/paper/main.tex`。
- 明确 Agent 不取代设计师；推荐高层策略用 Agent、低层安全控制用传统规则的混合方案。

---

### Task 1: 创建可讲解的中文幻灯片源文件

**Files:**
- Create: `docs/student-report/game-ai-agent-intro.tex`
- Test: `docs/student-report/game-ai-agent-intro.tex`（XeLaTeX 编译）

**Interfaces:**
- Consumes: 设计规格中的九页标题与教学顺序。
- Produces: 一份无需外部素材、可由 `latexmk -xelatex` 或 `xelatex` 编译的 Beamer 演示稿。

- [ ] **Step 1: 先创建一个会失败的编译检查命令**

运行：

```bash
mkdir -p /tmp/game-ai-agent-latex-check
cd /tmp/game-ai-agent-latex-check && xelatex -interaction=nonstopmode -halt-on-error /data/mogoo7zn/PulseArena/docs/student-report/game-ai-agent-intro.tex
```

预期：文件尚不存在，命令失败并报告找不到 `game-ai-agent-intro.tex`。

- [ ] **Step 2: 编写九页 Beamer 演示稿**

创建 `docs/student-report/game-ai-agent-intro.tex`，结构必须如下：

```latex
\documentclass[aspectratio=169,UTF8,10pt]{ctexbeamer}
% 定义蓝、青、橙三色与 TikZ 节点样式
\begin{document}
\begin{frame}\titlepage\end{frame}
% 依次放入：游戏目标、无 Agent 的敌人、状态机、传统方案问题、
% Agent 闭环、适应性、混合架构、结论
\end{document}
```

每页用一句醒目的口语化结论开场；关键术语在首次出现时带简短解释。至少包括：脚本敌人流程图、有限状态机、规则膨胀图、Agent 观察—决策—行动—反馈闭环、混合控制架构，以及脚本与 Agent 的对比表。

- [ ] **Step 3: 运行编译检查并确认 PDF 页数**

运行：

```bash
mkdir -p /tmp/game-ai-agent-latex-check
cd /tmp/game-ai-agent-latex-check && xelatex -interaction=nonstopmode -halt-on-error /data/mogoo7zn/PulseArena/docs/student-report/game-ai-agent-intro.tex
pdfinfo game-ai-agent-intro.pdf | rg '^Pages:'
```

预期：XeLaTeX 无错误退出，且 `pdfinfo` 输出 `Pages:           9`。

- [ ] **Step 4: 检查布局错误与内容边界**

运行：

```bash
rg -n 'Overfull|Undefined control sequence|LaTeX Error' /tmp/game-ai-agent-latex-check/game-ai-agent-intro.log
rg -n '\\begin\{frame\}' docs/student-report/game-ai-agent-intro.tex
```

预期：日志不匹配任何错误；源文件中包含 9 个 `frame` 环境。

- [ ] **Step 5: 提交独立报告文件**

```bash
git add docs/student-report/game-ai-agent-intro.tex
git commit -m "docs: add introductory game AI agent presentation"
```

预期：提交只包含新增的演示稿源文件；若 Git 元数据仍不可写，保留文件并在交付说明该环境限制。

## Self-review

- 规格覆盖：Task 1 交付独立 Beamer 文件、九页结构、通俗中文、TikZ 图示、传统方案与 Agent 的比较、混合架构和可编译校验，覆盖全部规格要求。
- 占位符扫描：计划未含 TBD、TODO 或“稍后实现”等占位项。
- 一致性：文件路径、编译命令和 PDF 名称均为 `game-ai-agent-intro`；页面数量检查与规格一致。
