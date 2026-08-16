"""Backward-compatible shim. See :mod:`training.core.runtime` for the implementation."""
from training.core.runtime import AgentModelInfo, RuntimeAgentPolicy, resolve_path

__all__ = [
    "AgentModelInfo",
    "RuntimeAgentPolicy",
    "resolve_path",
]