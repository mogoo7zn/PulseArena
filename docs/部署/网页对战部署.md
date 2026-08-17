# 网页对战部署指南 — 让训练好的 Agent 在浏览器里陪你玩

> 把 `promoted` 五档难度模型（easy / casual / normal / strong / elite）通过浏览器跑起来的完整流程。

---

## 1. 概述

浏览器里跑的 Godot 游戏 **不能** 直连 TCP 端口（HTML5 安全沙箱只允许 HTTP/HTTPS/WebSocket）。要让浏览器里的 Godot 客户端把每帧 142 维战术特征发给训练好的 `.pt` checkpoint、收到决策再返回，**必须**有一个 WebSocket ↔ TCP 桥做协议转换。

本仓库的 `demo-web-candidate-playtest` 分支已经把这套链路全部实现：

| 组件 | 文件 | 作用 |
|---|---|---|
| 推理服务 | `training/inference/serve_agent.py` | TCP JSONL 服务，端口 `8766`，加载 9 个 model manifest（5 档难度 + 4 候选） |
| WebSocket 桥 + 静态文件服务 | `scripts/linux/web_preview_server.py` | 端口 `8080`，单进程同时承担「HTTP 静态服务 `build/web/`」和「WebSocket 透传到 `serve_agent`」 |
| 浏览器侧 Godot | `build/web/index.{html,wasm,pck}` | 已编译好的 HTML5 build，里面已经接好 WebSocket 客户端 |
| 端到端冒烟测试 | `tests/smoke/web_candidate_playtest_check.py` | 纯 Python 起 WS 握手 + 发 `act_tactical`，验证决策真的从 checkpoint 透传到浏览器侧 |

---

## 2. 架构

```
┌─────────────────────┐    HTTP GET /index.html,…     ┌────────────────────────────────┐
│ 浏览器 (你 SSH 远端) │ �──────────────────────────► │  web_preview_server.py        │
│  Godot WebAssembly   │                               │  127.0.0.1:8080 (loopback)     │
│                     │    WS ws://host:8080/agent    │                                │
│                     │ ◄──────────────────────────► │   ├─ HTTP 静态服务 build/web/  │
│                     │    (JSONL，每帧一条决策)      │   └─ WS 桥 → TCP JSONL        │
└─────────────────────┘                               └────────────────┬───────────────┘
                                                                       │ TCP 127.0.0.1:8766
                                                                       ▼
                                                          ┌────────────────────────┐
                                                          │  serve_agent           │
                                                          │  0.0.0.0:8766          │
                                                          │  cuda:auto             │
                                                          └────────────┬───────────�
                                                                       │ torch
                                                                       ▼
                                                          training/checkpoints/hybrid/
                                                          hybrid_tactical_v2_promoted_
                                                          {easy|casual|normal|strong|elite}_20260816.pt
```

---

## 3. 前置依赖

| 项 | 说明 |
|---|---|
| Python | `.venv` 已就位（torch 2.11.0+cu128、CUDA 12.8、8×A100） |
| Godot Web build | `build/web/index.{html,wasm,pck}` 必须存在（已就位） |
| 5 个难度 checkpoint | `training/checkpoints/hybrid/hybrid_tactical_v2_promoted_{easy,c…,n…,s…,elite}_20260816.pt` 全部存在 |
| `model_catalog.json` | 已注册 5 档 tier manifest |

不需要额外安装什么——`.venv`、build artifacts、checkpoints 都已经在盘上。

---

## 4. 三步启动（全部后台运行）

### 步骤 ① 启动推理服务 `serve_agent`

```bash
cd /data/mogoo7zn/PulseArena
.venv/bin/python -m training.inference.serve_agent \
    --catalog training/models/model_catalog.json \
    --host 0.0.0.0 --port 8766 \
    --device auto \
    > /tmp/serve_agent.log 2>&1 &
echo "serve_agent pid=$!"
```

- 等待约 5 秒，模型权重加载完毕后日志会打印 `{"agent_server": "listening", "host": "0.0.0.0", "port": 8766, ...}`
- 监听 `0.0.0.0:8766` 意味着 `8766` 端口对所有网卡开放（包括 SSH 端口转发目标侧）

### 步骤 ② 启动 Web 桥 + 静态文件服务

```bash
cd /data/mogoo7zn/PulseArena
python3 scripts/linux/web_preview_server.py \
    --directory /data/mogoo7zn/PulseArena/build/web \
    --host 127.0.0.1 --port 8080 \
    --agent-host 127.0.0.1 --agent-port 8766 \
    > /tmp/web_preview.log 2>&1 &
echo "ws bridge pid=$!"
```

- 监听 `127.0.0.1:8080`，**只接受 loopback**——这是设计上的安全策略（见 §9 故障排查）
- 日志会打印 `Pulse Arena Web preview listening at http://127.0.0.1:8080/`
- 它会同时：
  - 对 `GET /`、`GET /index.wasm`、`GET /index.pck` 等返回 `build/web/` 静态文件
  - 对 `GET /agent` 带 `Upgrade: websocket` 头返回 101 升级，然后把每条 WS 文本帧作为 JSONL 透传到 `127.0.0.1:8766`

### 步骤 ③ 浏览器打开游戏

- **本机浏览器**：直接打开 `http://127.0.0.1:8080/`
- **SSH 远端机器**：见 §5

打开后会看到 Godot 加载画面 → 主菜单 → 选 `human_vs_1_agent` 模式 → 选地图 → **选 Agent Difficulty（5 档下拉）和 Agent Model（9 个候选下拉）** → 点 Start。

---

## 5. SSH 远端访问

`web_preview_server.py` 只绑 `127.0.0.1`（loopback），是为了不直接把游戏服务器暴露到公网。从 SSH 远端机器访问，需要端口转发：

```bash
# 在你本地笔记本上
ssh -L 8080:127.0.0.1:8080 user@<服务器IP>
# 然后本地浏览器打开 http://127.0.0.1:8080/
```

只要 SSH 隧道打通，浏览器加载 `index.html` → 浏览器里的 Godot 通过 `ws://127.0.0.1:8080/agent` 连服务器侧 → 桥透传到 `serve_agent` → checkpoint 出决策 → 一路返回给浏览器。

> 如果想从远端**直接用 IP**访问（不需要 SSH 隧道），需要改 `web_preview_server.py` 的 `LOOPBACK_HOSTS` 校验并把 `--host 0.0.0.0` 启动，但**强烈不建议**——浏览器端 Godot 没认证、决策 API 没鉴权，任何能访问 8080 的人都能消耗你的 GPU。

---

## 6. 难度档位选择（5 档）

在 Godot 主菜单右栏：

- **Agent Difficulty** 下拉：`Easy / Casual / Normal / Strong / Elite`
  - 对应 temperature `T`：1.6 / 1.1 / 0.85 / 0.55 / 0.25
  - 对应 `soften`/`safe` 等推理参数（见 `inference_profile.strength`）
- **Agent Model** 下拉：列出 9 个 model_id（默认按选中的难度自动匹配到对应 tier model，也可以手动覆盖选别的）

| 难度 | 训练好的 model_id（推荐） |
|---|---|
| Easy | `hybrid_tactical_v2_promoted_easy_20260816` |
| Casual | `hybrid_tactical_v2_promoted_casual_20260816` |
| Normal | `hybrid_tactical_v2_promoted_normal_20260816` |
| Strong | `hybrid_tactical_v2_promoted_strong_20260816` |
| Elite | `hybrid_tactical_v2_promoted_elite_20260816` |

游戏开局后，Godot 客户端会以 ~60Hz 频率把当前帧的 142 维战术特征 + 4 个 action mask（target_slot=7 / movement_mode=12 / fire_mode=6 / skill_mode=6）通过 WebSocket 发到桥，桥透传到 `serve_agent` 选中的模型，~6ms 拿到决策再返回。

---

## 7. 端到端冒烟测试

不需要打开浏览器也能验证整条链路：

```bash
python3 tests/smoke/web_candidate_playtest_check.py \
    --url http://127.0.0.1:8080/ \
    --host 127.0.0.1 --port 8080 \
    --model-id hybrid_tactical_v2_promoted_strong_20260816
```

期望输出形如：

```json
{"web_candidate_playtest": "ok", "model_id": "hybrid_tactical_v2_promoted_strong_20260816",
 "decision": {"target_slot": 4, "movement_mode": 10, "fire_mode": 3, "skill_mode": 0,
              "confidence": 0.16147753596305847, "protocol_version": 2}}
```

这条脚本做的事和浏览器里 Godot 做的事**完全一样**：HTTP 拉首页（验证 build artifact 可服务）→ WebSocket 握手 → 发 `act_tactical` → 收决策并校验 `model_id` 一致。

---

## 8. 进程管理

| 进程 | 默认端口 | 日志 | 查 pid |
|---|---|---|---|
| `serve_agent` | `8766` | `/tmp/serve_agent.log` | `ss -ltnp \| grep 8766` |
| `web_preview_server.py` | `8080` | `/tmp/web_preview.log` | `ss -ltnp \| grep 8080` |

```bash
# 看监听
ss -ltn | grep -E ":(8080|8766) "

# 优雅停止
kill $(ss -ltnp | grep ':8766 ' | grep -oE 'pid=[0-9]+' | cut -d= -f2)
kill $(ss -ltnp | grep ':8080 ' | grep -oE 'pid=[0-9]+' | cut -d= -f2)

# 强杀（万不得已）
pkill -9 -f training.inference.serve_agent
pkill -9 -f web_preview_server.py
```

---

## 9. 故障排查

### 9.1 `OSError: [Errno 98] Address already in use`

端口被占（很可能是上次没干净退出的进程）：

```bash
# 看占用
ss -ltnp | grep -E ":(8080|8766) "

# 强杀旧进程
for p in $(ss -ltnp | grep -E ':(8080|8766) ' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u); do
    kill -9 $p
done
```

### 9.2 浏览器里 Godot 启动后对手 AI "傻"（脚本化兜底）

浏览器里的 `HybridAgentController` 每帧会尝试连 WebSocket。如果 WS 连不上或决策超时，会**自动 fallback 到 scripted teacher**——表现就是"AI 不再用训练模型"。排查：

1. 打开浏览器开发者工具 → Console / Network → 找 `ws://…:8080/agent` 的连接状态
2. 确认 `web_preview_server.py` 在跑（`ss -ltn | grep 8080`）
3. 确认 `serve_agent` 在跑（`ss -ltn | grep 8766`）
4. SSH 隧道是否还活着（`ssh -L` 长连接可能被中间网络断）

### 9.3 smoke 测试报 `Mask shape (X, N) does not match logits (X, M)`

mask 维数与模型 logits 维数对不上。当前模型的合法维数：

- `target_slot`: **7** (`[True]*7`)
- `movement_mode`: **12** (`[True]*12`)
- `fire_mode`: **6** (`[True]*6`)
- `skill_mode`: **6** (`[True]*6`)

`tests/smoke/web_candidate_playtest_check.py` 已经按这套维数发。如果你自定义客户端脚本时遇到这个错，按上面四组数字改正即可。

### 9.4 `web_preview_server.py` 拒绝绑定非 loopback 地址

启动时如果传 `--host 0.0.0.0` 会立刻抛 `ValueError: Preview server must bind to a loopback address`。这是故意的（见 §5）。需要从外网访问请走 SSH 隧道，不要试图关掉这个校验。

### 9.5 浏览器加载卡在 Godot loading screen 不动

打开浏览器 Console 看 WebAssembly 加载错误。最常见原因：

- `index.wasm` 太大（~40MB）首字节延迟高 → 检查 `curl -o /dev/null -w "%{size_download}\n" http://127.0.0.1:8080/index.wasm` 是不是返回 39,509,339 字节
- `SharedArrayBuffer` 不可用（需要响应头 `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp`，`web_preview_server.py` 已经设好）

---

## 10. 一键启动脚本（推荐）

把以下内容存成 `scripts/linux/start_web_playtest.sh` 并 `chmod +x`：

```bash
#!/usr/bin/env bash
# 启动 Pulse Arena 网页对战所需的两个服务（推理 + Web 桥）。
set -euo pipefail
cd "$(dirname "$0")/../.."

# 1. 推理服务
.venv/bin/python -m training.inference.serve_agent \
    --catalog training/models/model_catalog.json \
    --host 0.0.0.0 --port 8766 \
    --device auto \
    > /tmp/serve_agent.log 2>&1 &
echo "serve_agent pid=$!"

# 2. Web 桥 + 静态服务
python3 scripts/linux/web_preview_server.py \
    --directory "$(pwd)/build/web" \
    --host 127.0.0.1 --port 8080 \
    --agent-host 127.0.0.1 --agent-port 8766 \
    > /tmp/web_preview.log 2>&1 &
echo "ws bridge pid=$!"

sleep 4
echo "--- listening ---"
ss -ltn | grep -E ":(8080|8766) "
echo "--- logs ---"
echo "serve_agent: tail -f /tmp/serve_agent.log"
echo "ws bridge : tail -f /tmp/web_preview.log"
echo "--- open in browser ---"
echo "  http://127.0.0.1:8080/"
```

启动后浏览器开 `http://127.0.0.1:8080/` 即可开战。
