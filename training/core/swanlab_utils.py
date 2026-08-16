"""Backward-compatible shim. See :mod:`training.core.training.swanlab` for the implementation."""
from training.core.training.swanlab import finish, init_swanlab, log, start_dashboard

__all__ = ["finish", "init_swanlab", "log", "start_dashboard"]