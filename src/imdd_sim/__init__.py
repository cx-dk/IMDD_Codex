"""IMDD PAM4 simulation platform."""

from .config import PlatformConfig, load_config
from .pipeline import SimulationResult, run_simulation
from .profiles import get_profile, list_profiles

__all__ = [
    "PlatformConfig",
    "SimulationResult",
    "get_profile",
    "list_profiles",
    "load_config",
    "run_simulation",
]

__version__ = "0.1.0"

