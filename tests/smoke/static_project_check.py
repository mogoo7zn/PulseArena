from __future__ import annotations
# 静态项目检查脚本，验证关键资源、脚本令牌和配置文件存在。

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

REQUIRED = [
    "project.godot",
    "scenes/app/Main.tscn",
    "scenes/menu/MainMenu.tscn",
    "scenes/arena/ArenaRoot.tscn",
    "scenes/arena/ArenaCross.tscn",
    "scenes/gameplay/Player.tscn",
    "scenes/gameplay/Projectile.tscn",
    "scenes/ui/GameHUD.tscn",
    "scripts/gameplay/character_animation_controller.gd",
    "scripts/gameplay/character_renderer.gd",
    "scripts/gameplay/weapon_renderer.gd",
    "scripts/gameplay/world_health_bar.gd",
    "scripts/gameplay/projectile_renderer.gd",
    "scripts/gameplay/combat_feedback_controller.gd",
    "scripts/gameplay/camera_effects.gd",
    "scripts/rl/player_action.gd",
    "scripts/rl/agent_observation.gd",
    "scripts/rl/observation_builder.gd",
    "scripts/rl/visibility_filter.gd",
    "scripts/rl/environment_bridge.gd",
    "scripts/rl/reward_calculator.gd",
    "scripts/controllers/player_controller.gd",
    "scripts/controllers/human_controller.gd",
    "scripts/controllers/scripted_agent_controller.gd",
    "scripts/replay/replay_manager.gd",
]


def fail(message: str) -> None:
    print(f"FAIL: {message}")
    sys.exit(1)


def main() -> None:
    for rel in REQUIRED:
        if not (ROOT / rel).exists():
            fail(f"missing required file: {rel}")

    text = "\n".join(p.read_text(encoding="utf-8", errors="ignore") for p in ROOT.rglob("*.gd"))
    for class_name in [
        "PlayerAction",
        "AgentObservation",
        "PlayerController",
        "HumanController",
        "ScriptedAgentController",
        "ModelAgentController",
        "HybridAgentController",
        "RemoteAgentController",
        "ONNXAgentController",
        "ReplayController",
        "EnvironmentBridge",
        "RewardCalculator",
        "VisibilityFilter",
        "HighLevelDecision",
        "HybridCombatExecutor",
        "TacticalFeatureBuilder",
        "BallisticAimSolver",
        "FireControl",
        "ProjectileThreatAnalyzer",
        "MovementExecutor",
        "CoverAnalyzer",
        "StuckRecovery",
        "HybridAgentConfig",
        "CharacterAnimationController",
        "CharacterRenderer",
        "WeaponRenderer",
        "ProjectileRenderer",
        "CombatFeedbackController",
        "CameraEffects",
        "WorldHealthBar",
    ]:
        if f"class_name {class_name}" not in text:
            fail(f"missing class_name {class_name}")

    project = (ROOT / "project.godot").read_text(encoding="utf-8")
    if 'run/main_scene="res://scenes/app/Main.tscn"' not in project:
        fail("main scene not configured")
    if "common/physics_ticks_per_second=60" not in project:
        fail("physics tick rate not set to 60")

    web_preset = (ROOT / "export_presets.cfg").read_text(encoding="utf-8")
    if not re.search(r"\[preset\.1\.options\]\s+variant/thread_support=false", web_preset):
        fail("Web export preset must define non-threaded options")
    for rel in ("archive/legacy_raw_ai/.gdignore", "training/runs/.gdignore", "build/.gdignore"):
        if not (ROOT / rel).is_file():
            fail(f"missing Godot scan exclusion: {rel}")

    missing_refs = []
    pattern = re.compile(r'res://([^"\n]+)')
    for file in list(ROOT.rglob("*.gd")) + list(ROOT.rglob("*.tscn")) + [ROOT / "project.godot"]:
        content = file.read_text(encoding="utf-8", errors="ignore")
        for match in pattern.finditer(content):
            target = ROOT / match.group(1)
            if not target.exists():
                missing_refs.append(f"{file.relative_to(ROOT)} -> {match.group(0)}")
    if missing_refs:
        fail("missing resource references:\n" + "\n".join(missing_refs))

    balance = (ROOT / "scripts/config/game_balance.gd").read_text(encoding="utf-8")
    for token in [
        "Vector2(2160, 1215)",
        "time_limit: float = 90.0",
        "agent_decision_hz: int = 15",
        "respawn_delay: float = 1.5",
        "projectile_damage: float = 20.0",
        "dash_distance: float = 130.0",
        "shield_duration: float = 0.5",
    ]:
        if token not in balance:
            fail(f"missing balance token: {token}")

    print("PASS: Pulse Arena static project check")


if __name__ == "__main__":
    main()
