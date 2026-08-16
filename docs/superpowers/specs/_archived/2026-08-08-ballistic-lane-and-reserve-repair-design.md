# Ballistic Lane and Energy Reserve Repair Design

## Goal

Keep the existing `legal_window_pressure` PPO route and repair the remaining
four-map combat bottlenecks without weakening blind-fire, projectile-threat, or
emergency safety.  The repaired policy must seek a route that is legal for the
same predicted intercept point used by firing, and its audit must explain which
energy-reserve rule rejected a legal shot.

## Evidence

The completed post-mask four-map candidate is mechanically stable: 33,324
environment steps, zero raw steps, a stable PPO KL, all four maps represented,
and a realized authorization rate of 49 / 3,125 = 1.57%.  It remains unsuitable
for expansion because 1,665 / 3,125 fire intents (53.3%) were rejected for
line-of-sight.  The failure is concentrated in Sky City (68.4%) and Mist World
(72.0%).  `reserved_energy` rejected another 824 intents (26.4%).

`TacticalFeatureBuilder._has_reachable_visible_enemy` tests the current enemy
position, while `BallisticAimSolver` tests the predicted intercept point.  A
current lane can be open while the lead trajectory crosses a wall; this makes a
spacing action legal at policy-selection time and blocks it during fire
execution.  The existing audit records only the later fire result and cannot
separate a stale/current lane from an intercept-lane failure.  The reserve audit
records the final rejection but not whether dash readiness, shield readiness,
low health, or projectile threat determined the reserve.

## Design

### Shared ballistic lane contract

Add a small public helper at the ballistic-solver boundary that evaluates a
candidate enemy using the same intercept solution, lifetime, line-of-sight, and
wall test used by firing.  It returns the predicted aim point and a compact
lane status.  `TacticalFeatureBuilder` uses that contract for
`legal_window_pressure` fire and movement masks.  It retains the current
non-pressure behavior unchanged.

When there is an observed target but no legal ballistic lane, blind spacing
actions (`HOLD`, `KEEP_RANGE`, strafes, and `RETREAT`) remain illegal. `CHASE`
continues to be legal so movement execution can seek a lane.  The movement
executor's existing multi-radius vantage search evaluates candidate locations
against the predicted intercept lane rather than the current target point.  It
does not bypass cover, hazard, or emergency-evasion checks.

### Explainable reserve audit

`FireControl` returns a structured reserve basis alongside the numeric reserve:
the winning reason and effective reserve ratio.  The safe environment bridge
exports those scalar/string diagnostics.  The PPO audit aggregates
`reserved_energy` rejections by reserve basis and map.  This phase changes no
reserve thresholds; training evidence decides whether any threshold change is
safe.

### Training protocol

Collect 32 fresh balanced four-map hybrid replays, train a fresh BC checkpoint,
and warm-start four independent 16k PPO diagnostics on GPUs 4–7.  Each run has
an isolated output directory, port, and seed.  Results are aggregate-only and
are never auto-promoted.

The candidate may proceed to larger training only when all runs have zero raw
steps, no transport/service fallback, both audit-consistency flags true, all
four maps represented in the aggregate, realized authorization at least 1.5%,
hit conversion at least 25%, and Sky City/Mist World each improve their
authorization rate while their intercept-line blocks decrease from the present
baseline.  Reserve changes are deferred unless the new reserve-basis audit
identifies one dominant non-emergency cause.

## Tests

Godot tests cover a target whose current position is visible but whose predicted
intercept lies behind a wall: the pressure action mask must deny blind spacing
and retain `CHASE`; the vantage route must choose a safe side with a ballistic
lane.  Fire-control tests cover each reserve winning reason. Python tests cover
safe diagnostic export and per-map aggregation of reserve-basis counters.

## Scope

Only the training-only pressure profile, ballistic/feature/movement hand-off,
diagnostics, tests, and isolated training plans change.  The baseline profile,
deployed models, reward rules, emergency thresholds, and automatic model
promotion remain unchanged.
