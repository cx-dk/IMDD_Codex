"""Process-based Monte Carlo orchestration for CPU-only hosts."""

from __future__ import annotations

from concurrent.futures import ProcessPoolExecutor
from dataclasses import replace
from typing import Any

import numpy as np

from .config import PlatformConfig
from .pipeline import run_simulation


def _trial(config: PlatformConfig, seed: int) -> dict[str, Any]:
    trial_config = replace(
        config,
        simulation=replace(config.simulation, seed=seed),
    )
    result = run_simulation(trial_config)
    return {"seed": seed, **result.metrics}


def run_monte_carlo(
    config: PlatformConfig,
    trials: int,
    workers: int,
) -> dict[str, Any]:
    if trials < 1:
        raise ValueError("trials must be positive")
    if workers < 1:
        raise ValueError("workers must be positive")
    seeds = [config.simulation.seed + 104729 * index for index in range(trials)]
    if workers == 1:
        results = [_trial(config, seed) for seed in seeds]
    else:
        with ProcessPoolExecutor(max_workers=workers) as executor:
            results = list(executor.map(_trial, [config] * trials, seeds))
    total_bits = sum(int(item["bits_compared"]) for item in results)
    total_errors = sum(int(item["bit_errors"]) for item in results)
    bers = np.asarray([float(item["pre_fec_ber"]) for item in results])
    pooled_ber = total_errors / total_bits if total_bits else float("nan")
    # Wilson score interval remains meaningful when no errors are observed.
    if total_bits and np.isfinite(pooled_ber):
        z = 1.96
        denominator = 1.0 + z * z / total_bits
        center = (pooled_ber + z * z / (2.0 * total_bits)) / denominator
        half_width = (
            z
            * np.sqrt(
                pooled_ber * (1.0 - pooled_ber) / total_bits
                + z * z / (4.0 * total_bits * total_bits)
            )
            / denominator
        )
        confidence_interval = [max(0.0, center - half_width), min(1.0, center + half_width)]
    else:
        confidence_interval = [float("nan"), float("nan")]
    return {
        "profile": config.profile,
        "trials": trials,
        "workers": workers,
        "total_bits": total_bits,
        "total_bit_errors": total_errors,
        "pooled_pre_fec_ber": pooled_ber,
        "mean_trial_ber": float(np.mean(bers)),
        "trial_ber_std": float(np.std(bers)),
        "wilson_95pct_interval": confidence_interval,
        "results": results,
    }
