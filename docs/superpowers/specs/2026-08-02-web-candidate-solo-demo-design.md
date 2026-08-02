# Web Candidate Solo Demo Design

## Goal

Let a player open the existing loopback-only Godot Web export and play a
human-versus-one-agent match against
`hybrid_tactical_v2_ppo_resume_candidate_20260802`.  The demo must make it
obvious whether the trained candidate is serving decisions or the game has
fallen back to Scripted Hard.

This is an isolated evaluation/demo path.  It must not change
`default_model_id`, promote a model, expose the inference port, or claim that
the candidate has passed competitive evaluation.

## Chosen Architecture

The existing browser export uses a model controller that assumes a raw TCP
JSONL connection.  The Web build instead needs a same-origin WebSocket
transport:

```text
Godot Web client
  -- WebSocket /agent (same origin) --> web preview gateway
  -- loopback TCP JSONL --> serve_agent --catalog training/models/model_catalog.json
  -- selected candidate --> TacticalActorCritic policy
```

The web preview gateway serves the exported static files and upgrades only
`/agent` requests to WebSocket.  It is bound only to `127.0.0.1` or `::1`.
The Python inference service remains loopback-only on port 8766 and is never
made browser-accessible.

Desktop/native Godot retains the current TCP controller.  Web builds select a
new WebSocket-backed variant through a platform check, while preserving the
same protocol-v2 JSON messages and response validation.

## User Experience

The existing main menu remains the entry point.  The demo defaults to the
candidate model but still presents the catalog model selector.  It starts the
existing `human_vs_1_agent` mode with a Hybrid Tactical Agent.

The runtime debug overlay must show these fields for the agent:

- requested model ID and response model ID;
- transport connected/disconnected state;
- last inference latency;
- candidate-decision count;
- fallback count and latest fallback reason;
- latest fire-block reason and safety-override reason.

If the gateway or inference service is unavailable, the agent must keep the
existing safe Scripted Hard fallback behavior and the overlay must visibly say
that it is in fallback.  A fallback state cannot be presented as candidate
play.

## Components and Boundaries

### Web preview gateway

Extend the preview server rather than adding a public listener.  It owns:

- static Web export delivery and existing isolation headers;
- a same-origin `/agent` WebSocket endpoint;
- JSON message validation, one outstanding request per client, and forwarding
  to the configured loopback TCP inference service;
- explicit close/error responses when the upstream service is unavailable.

It does not load model weights, choose a model, or alter candidate decisions.

### Web model transport

Add a small controller/transport that mirrors the current Hybrid controller's
request sequencing, timeout handling, requested-model verification, and
fallback diagnostics.  It communicates through WebSocket only in Web builds.
The native controller stays unchanged.

### Demo launch path

Add a managed command that starts both the catalog-backed candidate service and
the web preview gateway, using the existing ownership/PID safeguards.  It must
fail cleanly if either owned service cannot start or its health check fails.
The command must not overwrite an existing managed service or change catalog
defaults.

## Protocol and Failure Handling

The WebSocket payload is the existing JSONL request object without newline
framing; every response is an object with the original `request_id`.
Only `act_tactical`, `health`, and `models` are proxied.  The gateway rejects
other commands and non-loopback upstream targets.

The Godot client sends the candidate model ID on every tactical decision
request.  A mismatched response, network error, malformed response, timeout,
low-confidence response, or safety guard activates the existing fallback
logic and updates visible diagnostics.

## Verification

Automated coverage will verify:

1. loopback-only binding and `/agent` upgrade validation;
2. WebSocket-to-TCP request/response forwarding with a fake upstream service;
3. rejected malformed and unsupported commands;
4. upstream disconnect/timeout causes a visible fallback status;
5. native paths retain TCP behavior;
6. a managed demo dry run uses the candidate ID and preserves the catalog
   default.

An end-to-end smoke check will start the candidate service on CPU, start the
loopback gateway, make a WebSocket `act_tactical` request, and assert the
response model ID is
`hybrid_tactical_v2_ppo_resume_candidate_20260802`.

Manual acceptance is: open the local web preview, select the candidate, start
Human vs 1 Agent, observe candidate-connected telemetry, then stop the model
service and observe an explicit Scripted Hard fallback indication.

## Non-Goals

- default-model promotion or production deployment;
- repairing the paired evaluator;
- preserving GRU state across inference calls;
- model retraining, catalog rewriting, public hosting, authentication, or
  multiplayer web service.
