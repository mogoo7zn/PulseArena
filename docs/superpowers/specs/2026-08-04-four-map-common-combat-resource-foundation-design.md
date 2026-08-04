# Four-Map Common Combat and Resource Foundation Design

## Goal

Repair the shared tactical learning loop before expanding playability training to all four maps. The resulting policy must learn that useful pressure is a realized chain from tactical decision to authorized projectile to hit, and that resources are worth contesting only when they create measurable combat or survival value.

The first training route is `legal_window_pressure`. It remains non-deployed until fixed-seed, per-map evaluation passes. `score_margin_discipline` is retained as a later control route and is out of scope for this implementation.

## Scope

This work changes only common tactical accounting, resource accounting, map-event attribution, and the playability curriculum configuration:

- tactical-decision-to-projectile-to-hit attribution;
- pickup collection and realized pickup-value accounting;
- map-event taxonomy for Dungeon, Sky City, Jungle, and Mist World;
- a single balanced four-map training plan built from one post-fix BC base;
- per-map audit and evaluator outputs.

It does not weaken wall, line-of-sight, projectile-lifetime, energy, friendly-fire, or emergency-avoidance safety gates. It does not promote a model catalog entry or change the default game model.

## Invariants

- Every learned transition remains protocol-v2 tactical; `raw_step_calls` must remain zero.
- Every projectile reward is attached to a decision generation that actually created an authorized projectile. A later snapshot cannot rewrite its attribution.
- A blocked fire intent receives no commitment or hit reward.
- Resource shaping must be value-based, not collection-count-based; walking through uncontested pickups while full health/energy must not create positive reward.
- All four maps use the same model base, reward profile, opponent mix, episode duration, seed policy, and PPO hyperparameters. Map identity and map mechanics are the only environment differences.
- All candidate selection uses fixed-seed per-map outcomes and realized events, never rollout reward alone.

## Decision-to-Fire Event Ledger

At every high-level decision generation, the Godot runtime creates a stable `decision_generation_id` for the player. It records the executed high-level decision and the decision-time facts required for attribution:

- selected target and target validity;
- line-of-sight/reachable-window result;
- energy, cooldown, safety override, and fire block reason;
- selected fire and movement modes;
- map id.

When a projectile is created, it inherits the owner decision generation. `RewardCalculator` records a single authorization event only when that exact generation had a valid target and an allowed fire window. When the projectile hits, its exact authorization record receives the hit and damage event. Projectile removal clears only that projectile record.

The learner receives cumulative event counters and per-generation deltas, not inferred firing success from the final snapshot after a multi-tick environment step. Snapshot diagnostics remain state-distribution data only.

Required counters include `fire_intent`, `fire_authorized`, `authorized_hit`, `authorized_damage`, and fire rejection counts keyed by reason. Audits must distinguish policy-controllable rejections (`hold_fire`, no valid tactical fire mode, unreachable chosen position) from legitimate safety restrictions (wall, no line of sight, cooldown, reserved energy, emergency projectile).

## Resource-Value Ledger

Pickup collection is an event, but is not itself a positive learning reward. At collection time the runtime records pickup type, collector, map id, whether an opponent was within the contested radius, and the immediately realizable effect.

The realized-value rules are:

| Pickup | Positive value condition | No positive reward condition |
| --- | --- | --- |
| Health | Actual restored HP | Collector was already at full health |
| Shield | Actual later shield absorption, attributed to the active pickup shield | Shield expires unused |
| Haste | Actual later authorized damage while the haste effect is active | Merely collecting or moving faster |
| Overcharge | Actual later authorized damage while the overcharge effect is active | Merely collecting the buff |
| Pulse | Existing actual damage/kill path only; no duplicate pickup reward | Pulse collection without useful outcome |
| Magnet | Audit-only collection/control event | All cases |

A small `contested_pickup_capture` shaping component may be granted only when a non-magnet pickup is collected while an alive enemy is within the configured contest radius. It is never granted for an uncontested collection and is capped once per pickup. The reward configuration exposes its coefficient and the contest radius.

The ledger reports collection counts by type, contested captures, actual healing, shield absorption, buff-attributed damage, pulse-attributed damage, and expired-unused resource counts. This enables resource policy selection without rewarding route farming.

## Map Event Taxonomy

All map-caused damage, deaths, and forced movement must carry one of these event sources into the reward calculator, replay, rollout audit, and evaluator:

| Map | Event source | Meaning |
| --- | --- | --- |
| Dungeon | `dungeon_trap` | Cage trap damage, lock, or death |
| Sky City | `sky_squeeze` | Moving-obstacle squeeze death |
| Sky City | `sky_void` | Void pull/core death |
| Jungle | `jungle_swamp` | Swamp slow and damage |
| Jungle | `jungle_snake` | Snake bite, lock, or death |
| Mist World | `mist_portal` | Portal traversal and forced relocation |
| Mist World | `mist_fog` | Fog exposure event; currently non-damaging |

Map events inherit the global environment damage/death penalties. The taxonomy does not add a hidden map-specific reward coefficient; it makes risk measurable and allows per-map gates to be meaningful.

## Four-Map Playability Curriculum

After the common foundation tests pass, `legal_window_pressure` uses one balanced plan across `dungeon`, `sky_city`, `jungle`, and `mist_world`. Each training cohort has equal episode allocation per map and uses fixed, disjoint seed sets. Every worker starts from the same post-fix BC checkpoint; independent workers are labeled independent candidates, never a shared multi-GPU learner.

The progression is:

1. Four-map combat/resource diagnostic: short, equal map allocation; verify fire and pickup accounting, non-zero realized damage, and map-event reporting.
2. Four-map pressure curriculum: legal contact, blocked-vantage movement, contested-resource starts, then full random starts; keep the same maps balanced at each stage.
3. Fixed-seed per-map evaluation: Dungeon, Sky City, Jungle, and Mist World each report match outcomes, score margins, authorized-hit conversion, resource value, and taxonomy-specific risk.

No checkpoint may be selected solely because it has higher training reward, higher chase volume, or a favorable single-map seed.

## Acceptance Gates

Before a longer four-map run:

- `raw_step_calls = 0` for every worker;
- every authorized hit maps to exactly one earlier authorized projectile and decision generation;
- blocked-fire decisions receive zero commitment/hit reward;
- a full-health uncontested health pickup produces zero positive pickup shaping;
- each map reports at least one map-event counter schema, even if its count is zero;
- all four maps are present with equal planned episode counts and the same BC checkpoint;
- per-map reports include outcome/score margin, fire conversion, resource-value totals, fallback, safety overrides, and environment-event totals.

Before candidate consideration:

- complete all configured holdout seeds, not a truncated smoke subset;
- evaluate every map against the scripted hard baseline;
- require non-draw evidence and non-zero realized combat on each map;
- retain environment, fallback, and safety guardrails;
- require human review for the playability route.

## Verification

The implementation must add focused Godot and Python tests for event attribution, no-reward-on-blocked-fire, anti-farming resource rules, map-event source propagation, four-map configuration balance, and evaluator completeness. It must run existing protocol, PPO, trainer, pipeline, and smoke tests before launching the bounded diagnostic.

The first live run is a bounded diagnostic, not a production training job. Its report must explicitly separate trustworthy realized-event evidence from open gameplay-quality uncertainty.
