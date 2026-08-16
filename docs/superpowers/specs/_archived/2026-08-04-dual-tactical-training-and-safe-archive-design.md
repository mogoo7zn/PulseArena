# Dual Tactical Training and Safe Archive Design

## Goal

Train two separately selectable high-level tactical policies from the same audited behavior-cloning base, after removing the pre-draw-fix training outputs from the active workspace:

- `hybrid_tactical_legal_window_pressure`: proactive, human-like pressure through legal engagement-window selection, pursuit, and sustained useful damage.
- `hybrid_tactical_score_margin_discipline`: competitive play optimized for true score margin, favorable exchanges, survival, and resource discipline.

Neither policy may use a pre-draw-fix PPO checkpoint as a resume source. Both start from the same audited tactical BC checkpoint so their comparison is attributable to their reward profiles and selection criteria.

## Non-goals

- Do not move or alter deployed/catalog assets: `hybrid_tactical_v1`, the two catalog candidate manifests, their checkpoint files, or `training/models/model_catalog.json` entries.
- Do not claim the current independent eight-worker runner is shared-learner MAPPO, DDP, or league training.
- Do not auto-promote either new policy to the default game model.

## Safe Archive

Move only pre-draw-fix run directories and evaluation directories into `training/runs/archived/pre_draw_fix/`, grouped by source purpose. Preserve all files and update repository documentation/path references. Archived reports must state that their reward-based model selection is invalidated by the former draw-as-win defect.

The following remain in place because they are deployed or catalog-addressable:

- `training/models/hybrid_tactical_v1_agent.json`
- `training/models/hybrid_tactical_v2_ppo_expanded_candidate_20260802_agent.json`
- `training/models/hybrid_tactical_v2_ppo_resume_candidate_20260802_agent.json`
- `training/checkpoints/hybrid/hybrid_tactical_v2_ppo_expanded_candidate_20260802.pt`
- `training/checkpoints/hybrid/hybrid_tactical_v2_ppo_resume_candidate_20260802.pt`

New post-fix evaluations remain active under `training/runs/evaluations/` as regression evidence.

## Reward Profiles

Both profiles preserve hard safety constraints: invalid masked actions are impossible, draw has zero outcome reward, environment deaths are negative, and executor overrides remain measurable. Reward is assigned from realized state transitions and explicit executor diagnostics, not from an intent that was blocked.

### Legal Window Pressure

Purpose: create visible, sustained combat pressure while retaining enough survival discipline for meaningful play.

- Positive: damage dealt after a policy-selected, executor-authorized legal shot; kill contribution; entering/maintaining a valid engagement range; sustained target commitment during an actionable window; successful pursuit that leads to damage.
- Negative: holding or selecting a non-engaging fire mode while a legal favorable window persists; rapid target churn without damage; retreating or using defensive skills without a threat; environment damage/death; repeated safety overrides; selected engagement attempts rejected for policy-controllable reasons.
- Small terminal contribution: true win and positive score margin only. It must not dominate dense combat terms.

### Score Margin Discipline

Purpose: maximize real competitive result without rewarding draw farming or unnecessary exposure.

- Positive: true score-margin improvement, damage exchange surplus, kill contribution, survival, objective/pickup value, and resource-efficient legal damage.
- Negative: damage taken, death, environment hazards, empty or low-value attacks, wasteful skill/energy use, unfavorable exchanges, and avoidable safety overrides.
- Terminal contribution: true win and positive score margin. Draw is exactly zero.

## Instrumentation Contract

Every tactical transition must make it possible to attribute reward to the policy decision and executor result. Audits must include:

- reward-component totals and per-episode rates;
- target selection/change counts and target-valid/actionable-window counts;
- fire intent, fire allowed, block-reason histogram, legal-window miss rate, and policy-controllable rejection rate;
- damage, kill, death, environment damage/death, score margin, and draw rate;
- safety override count/reason histogram, fallback count/reason histogram, raw-step calls;
- per-profile fixed-seed evaluation reports.

## Training and Evaluation Sequence

1. Verify the fixed draw/result/reward contract with unit and Godot TCP smoke tests.
2. Run identical small 1v1 fixed-seed diagnostics from the BC base for both profiles; use full 90-second matches on Dungeon only.
3. Compare true non-draw rate, score margin, damage, legal-window conversion, fire-block rate, override/fallback rates, and behavior distribution. Do not select by rollout reward alone.
4. Expand only a profile that shows real positive score-margin episodes and a measurable behavioral improvement. Add maps before FFA and 2v2.
5. Run fixed-seed four-map, 1v1/FFA/2v2 evaluations before any catalog promotion. Human review is required for the pressure policy.

## Acceptance Gates

Diagnostics must satisfy all of the following before a longer run:

- `raw_step_calls = 0`;
- no draw-as-win reward or score-reporting regression;
- at least one non-draw fixed-seed episode and non-zero realized damage;
- fallback is reported and not used as evidence of learned policy strength;
- model selection metrics are based on fixed-seed match outcomes, score margin, and safety/behavior guardrails;
- the pressure policy demonstrates higher legal-window engagement/damage than the disciplined policy without exceeding agreed environment-death and safety-override limits.

## Naming Convention

Names identify the intervention and intended behavior, never a bare version number:

- configs/runs/checkpoints use `legal_window_pressure` or `score_margin_discipline`;
- model IDs are `hybrid_tactical_legal_window_pressure` and `hybrid_tactical_score_margin_discipline`;
- archived material uses `pre_draw_fix` to explain its limitation.
