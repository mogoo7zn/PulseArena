# Pressure Reward Accountability Design

## Goal

Make the experience-oriented tactical policy learn visible, sustained, legal combat pressure from correctly attributed events, then run a gated four-GPU training cohort only when the evidence is trustworthy.

## Evidence and Decision

The completed four-GPU diagnostic produced non-zero legal-window damage while its snapshot audit reported zero or near-zero `fire_allowed_count`. The reward calculator records the authorization at projectile creation, whereas the trainer samples only the final executor diagnostics after a multi-tick step. Consequently, the audit can miss the event that generated the reward. This makes current fire-conversion figures unsuitable for model selection.

Do not start full-scale training yet. First make projectile authorization and realized hits authoritative event counters. Then measure pressure with those counters, rather than lowering fire gates repeatedly.

## Design

### Event-accountable engagement

`RewardCalculator` will maintain per-player cumulative event counters for:

- executor-authorized projectiles;
- authorized projectiles that dealt damage;
- legal-window commitment events;
- missed actionable legal windows;
- pressure-retreat decisions, defined as retreat while a valid target is inside engagement range, the executor reports an actionable firing window, and no projectile threat or emergency safety override is active.

`EnvironmentBridge` exposes only those aggregate counters to the tactical learner. `tactical_online_trainer.py` consumes their deltas exactly as it already consumes cumulative reward-component deltas. Snapshot diagnostics remain useful for state distributions and block reasons but are not used as the source of truth for firing conversion.

### Experience reward profile

Keep hard constraints: no shots through walls, no friendly fire, no unavailable action, and emergency evasion has no aggression penalty.

For `legal_window_pressure`:

- reward authorized legal-window commitment once, not per simulation tick;
- reward authorized-hit damage and kills as realized outcomes;
- penalize a missed actionable window only for `HOLD_FIRE` and only once per decision generation;
- penalize threat-free pressure retreat only when target range, legal line, and safety facts prove it was a controllable withdrawal;
- do not reward bare chase movement, blocked fire intent, or scripted fallback.

### Persistent firing-vantage movement

For the pressure profile, `MovementExecutor` retains a safe lateral route direction for a short bounded window when the known target is blocked. It only drops that route when a legal lane appears, an emergency threat occurs, or the route becomes unsafe. This prevents immediate reversal back into a wall-facing direct chase.

### Gates before full scale

Run a four-GPU, fixed-seed cohort of 90-second scripted-opponent matches after the changes. It may become a longer full-scale campaign only if all conditions hold across the cohort:

- `raw_step_calls == 0` and event-counter deltas are non-negative and internally consistent;
- at least 12 authorized projectile events and at least 4 authorized hits in aggregate;
- authorized-shot to tactical-decision rate is at least 0.5%;
- no-line-of-sight blocks are below 45% of fire-intent decisions;
- pressure-retreat penalty is measurable but does not coincide with emergency overrides;
- no candidate checkpoint is deployed automatically.

If a gate fails, retain the output as a diagnostic artifact and revise the relevant mechanism instead of extending its training budget.

## Non-goals

- No wall-penetrating shots or private-state observations.
- No automatic catalog promotion, checkpoint replacement, or movement of deployed assets.
- No claim that four independent workers are a shared learner.

## Follow-on: reproducible service evaluation and resource-aware expansion

The contact-reset candidate must not be judged with a baseline reward profile or an
implicitly selected, busy GPU.  A tactical candidate manifest therefore carries the
immutable `reward_profile_id` used to produce it.  Evaluation copies that value into
the Godot `MatchConfig`, so controller feature construction, fire legality, and reward
telemetry use the same profile as training.  The evaluator accepts `cpu`, `auto`,
`cuda`, or an explicit `cuda:N` device; no device is silently remapped.

The service runner warms the model before starting the timed match.  Startup and warmup
are reported separately from per-decision latency, and any run with service timeout or
fallback above the gate is diagnostic only.  It is not treated as a policy regression
or promotion evidence.

The next training curriculum is staged rather than a direct extension of the
contact-reset result: short legal-contact initialization, then approach/vantage
episodes with distant or blocked targets, then 60--90 second resource-disciplined
matches.  The pressure objective rewards damage conversion and actionable-window entry;
it does not reward blocked intent or indiscriminate projectile expenditure.  Training
on GPUs 4--7 starts only after the repaired service evaluation shows the intended
profile, no material service fallback, and normal-spawn contact acquisition.
