# High-Playability Combat Loop Repair Design

## Goal

Keep the existing `legal_window_pressure` profile and PPO training route, while
making the intended high-playability loop executable and measurable: approach a
legal target, use cover or evasive movement under pressure, then re-engage and
fire through a legal line of sight.  This change is training-only and must not
alter the baseline/deployed hybrid controller.

## Evidence and Root Cause

The four-map resource-contest diagnostic completed with stable PPO mechanics
but did not produce enough realized combat:

- 1,899 fire intents produced only 23 authorized projectiles; when authorized,
  8 hit (34.8%).
- The dominant executor blocks were `no_line_of_sight` (1,048) and
  `reserved_energy` (650).
- `SEEK_COVER` was selected only 21 times, so the desired cover-to-reengage
  loop is absent rather than merely under-rewarded.
- The 16k-step run completed only four matches, with one or two matches per
  map; it is diagnostic evidence, not a promotion-scale PPO result.

The root cause is a configuration boundary mismatch.  `legal_window_pressure`
does tune the executor's firing thresholds and reserves, but the tactical
teacher still contains fixed cover and threat choices.  A JSON PPO plan therefore
cannot change the teacher trajectory that supplies the tactical prior, and the
existing aggregate audit cannot distinguish whether a blocked attack lacked a
vantage route, retained defensive energy, or failed to re-engage after cover.

## Chosen Approach

Use the existing `legal_window_pressure` identifier throughout.  Do not create
a new reward/profile identifier and do not relax emergency safety thresholds.

Expose the already intended high-playability controls from the existing hybrid
configuration to the tactical teacher:

1. Keep emergency threat handling and the hard high-threat escape behavior at
   the current safety envelope (0.72 high threat, 0.88 emergency).
2. For non-emergency pressure, route threat-aware low-health movement to
   `SEEK_COVER` only when nearby cover is observable; after the threat falls it
   returns through the existing visible-target chase/keep-range logic rather
   than holding cover indefinitely.
3. Preserve visibility-gated fire.  Adjust only the existing profile's
   non-emergency fire reserve and hit/aim settings after an isolated test
   proves the executor can issue the added shots without bypassing safety.
4. Add replay counters that form an actionable funnel per map: fire intent,
   line-of-sight block, reserve block, authorized projectile, hit, cover entry,
   and re-engagement after cover.  Counters use realized events; no reward is
   granted merely for selecting a tactical mode.

## Training Protocol

1. Add regression tests for the profile-to-teacher control mapping and the new
   replay events.  Run the tests red before implementation.
2. Run a short four-map collection/diagnostic on GPU 4 to establish whether the
   new behavior actually raises authorized-fire opportunity and records a
   cover-to-reengage loop.
3. Train a fresh, isolated four-map BC checkpoint from that collection, then
   run a GPU-4 PPO diagnostic warm-started from the fresh checkpoint.  This
   ensures the repaired cover-to-reengage teacher behavior reaches the PPO
   prior while preserving the same reward-profile identifier.  The candidate
   remains non-deployed.
4. Promote to a larger PPO run only if all guardrails hold: zero raw-action
   fallback, no safety-override regression, no map omitted, more authorized
   fire than the 1.2% diagnostic baseline without a material hit-rate collapse,
   and observed cover-to-reengage events.

## Failure Interpretation

- If authorized fire increases but hit rate collapses, restore the previous
  firing threshold: the relaxation is too permissive.
- If `no_line_of_sight` remains the dominant block, fix/measure vantage routing
  next; reward scaling and PPO duration are not causal remedies.
- If `reserved_energy` remains dominant after the profile value changes, trace
  the dynamic reserve floors in `FireControl` before changing PPO hyperparameters.
- If cover entry increases without re-engagement, correct movement execution;
  do not reward stationary hiding.
- If these controlled diagnostics pass but PPO does not improve, retain PPO as
  the fine-tuning stage and expand balanced behavior-cloning collection before
  running more PPO updates.

## Scope and Safety

Only the training-only `legal_window_pressure` profile, its teacher/executor
hand-off, replay diagnostics, tests, a training plan, and run documentation are
in scope.  Baseline profile behavior, deployed candidates, map reward rules,
and automatic model promotion remain unchanged.
