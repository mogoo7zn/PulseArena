# Linux 原生工作流

Pulse Arena 的正式开发、测试、训练和发布目标为 Ubuntu 24.04 x86_64。
游戏逻辑使用 Godot/GDScript，训练工具使用 Python，因此不需要重新实现
玩法代码；Linux 化的重点是工具链、命令入口、交付产物和旧模型兼容。

## 系统前置条件

- Python 3.10+ 与 `python3-venv`。
- Godot 4.7 Linux x86_64 binary；发布还需要对应版本的 Linux export
  templates。
- 训练需要 PyTorch、NumPy、Matplotlib；GPU 训练还需要兼容的 NVIDIA
  driver 与 CUDA PyTorch wheel。

安装 Python 环境：

```bash
sudo apt update
sudo apt install -y python3 python3-venv
make setup
```

将 Godot 放在 `PATH` 中，或显式设置路径：

```bash
export GODOT_BIN=/opt/godot/godot
```

CUDA wheel 不应由项目猜测。根据服务器驱动和 PyTorch 官方兼容表选择索引后，
在首次安装前设置 `TORCH_INDEX_URL`，例如：

```bash
export TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124
bash scripts/ops/bootstrap.sh --with-training
```

## 日常命令

```bash
make check             # 不需要 Godot 的静态检查
make test              # 静态、Godot 单元、地图和无头对局检查
make export-linux      # build/linux/PulseArena.x86_64
make train-preflight   # Python、Godot、CUDA 能力报告
make train-validate    # 验证本地训练计划
make package-server    # 生成 Linux 服务器训练包
```

`training/configs/local_settings.json` 是被 Git 忽略的个人配置。失效的旧绝对路径会被
`training/pipeline/run_stage.py` 自动跳过；`GODOT_BIN` 和 `--godot` 始终优先。

## 网页端调试与远程访问

网页导出需要安装与 Godot 4.7 匹配的 **Web export templates**。导出和本地预览
使用固定且安全的命令入口：

```bash
make web-export        # 写入 build/web/index.html
make web-start         # 仅监听 127.0.0.1:8080
make web-status        # 检查受管进程和本地 HTTP 健康状态
make web-stop          # 仅终止受管预览进程并清理状态文件
```

服务器不会监听公网地址，也不会开放训练/推理端口；端口 `8765` 与 `8766` 不属于
网页预览。通过 Cursor Remote SSH 开发时，复用现有连接即可：在 Cursor 已连接
工作区的 **Ports** 面板中转发 `8080`，然后在本地电脑浏览器访问
`http://127.0.0.1:8080/`。不需要手工执行额外的 SSH 隧道命令。预览结束后始终
执行 `make web-stop`。

游戏的浏览器开发调试面板默认隐藏。按 **F3** 或点击画布右上角的 **DEBUG** 控件
切换；它仅显示 FPS、帧耗时、对局状态、地图、剩余时间、玩家数、投射物数和最近
50 条公开事件。面板不传输网络数据，不显示训练/推理端点、控制器或策略内部状态、
私有能量/储备及冷却信息；无头和训练对局不会创建它。

## 交付产物

`export_presets.cfg` 定义了 `Linux x86_64` 发布预设。执行
`make export-linux` 后，二进制和配套 PCK 会出现在 `build/linux/`。该目录为
本地构建产物，不进入版本控制。

GitHub Actions 的 Linux 流程会下载匹配的 Godot 版本，执行完整无头测试，
并验证 Linux 导出。CI 使用的 `GODOT_VERSION` 和项目的 Godot 主版本必须同步
更新。

## 旧模型迁移

历史 `.pt` 文件可能序列化了其他平台的 `pathlib` 类型。运行时仍能在受限范围内
兼容读取它们，但只应对可信来源使用旧 pickle 回退。将文件转换一次即可得到不含
平台路径对象的新 checkpoint：

```bash
python training/model_io/migrate_legacy_checkpoint.py \
  --input archive/legacy_raw_ai/checkpoints/ppo_10m.pt \
  --output training/data/incoming_models/ppo_10m_portable.pt \
  --allow-legacy-pickle
```

转换程序会以 `weights_only=True` 重新读取输出文件进行验证。历史归档保留用于复现，
但不属于正式 Linux 运行、训练或发布依赖。
