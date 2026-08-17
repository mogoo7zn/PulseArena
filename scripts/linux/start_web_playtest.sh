#!/usr/bin/env bash
# 启动 Pulse Arena 网页对战所需的两个服务（推理 + Web 桥）。
# 用法： bash scripts/linux/start_web_playtest.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

# 1. 推理服务（5 档难度模型都加载）
.venv/bin/python -m training.inference.serve_agent \
    --catalog training/models/model_catalog.json \
    --host 0.0.0.0 --port 8766 \
    --device auto \
    > /tmp/serve_agent.log 2>&1 &
echo "serve_agent pid=$!"

# 2. Web 桥 + 静态服务（同时 serve build/web/ 和 ws://...:8080/agent）
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
