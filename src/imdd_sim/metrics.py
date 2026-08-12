"""PAM4 alignment, BER/SER, eye, and standard comparison metrics."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.typing import NDArray

from .models.signal import gray_demap_pam4, pam4_decisions

FloatArray = NDArray[np.float64]


@dataclass(frozen=True)
class AlignedSymbols:
    received: FloatArray
    transmitted: FloatArray
    lag: int
    polarity: int
    raw_ser: float


def align_symbol_streams(
    received: FloatArray,
    transmitted: FloatArray,
    max_lag: int = 512,
) -> AlignedSymbols:
    """Align received full-scale levels with normalized IEEE PAM4 TX levels.

    The transmitter drives the behavioral modulator with levels in ``[-1, 1]``;
    receiver DSP operates at conventional full-scale levels ``[-3,-1,+1,+3]``.
    Scaling the known TX sequence here keeps both sides on one decision scale.
    """
    limit = min(max_lag, max(1, received.size // 4), max(1, transmitted.size // 4))
    best: tuple[float, int, int, FloatArray, FloatArray] | None = None
    transmitted_scaled = transmitted * 3.0
    for polarity in (1, -1):
        candidate = polarity * received
        for lag in range(-limit, limit + 1):
            if lag >= 0:
                rx = candidate[lag:]
                tx = transmitted_scaled[: rx.size]
            else:
                tx = transmitted_scaled[-lag:]
                rx = candidate[: tx.size]
            size = min(rx.size, tx.size)
            if size < 128:
                continue
            rx = rx[:size]
            tx = tx[:size]
            compare = min(size, 4096)
            score = float(
                np.mean(pam4_decisions(rx[:compare]) != pam4_decisions(tx[:compare]))
            )
            if best is None or score < best[0]:
                best = (score, lag, polarity, rx, tx)
    if best is None:
        raise ValueError("unable to align symbol streams")
    return AlignedSymbols(best[3], best[4], best[1], best[2], best[0])


def error_metrics(received: FloatArray, transmitted: FloatArray) -> dict[str, Any]:
    """Compute SER and bit BER using the IEEE ``00,01,11,10`` Gray demapper."""
    size = min(received.size, transmitted.size)
    rx_indices = pam4_decisions(received[:size])
    tx_indices = pam4_decisions(transmitted[:size])
    rx_bits = gray_demap_pam4(rx_indices)
    tx_bits = gray_demap_pam4(tx_indices)
    symbol_errors = int(np.count_nonzero(rx_indices != tx_indices))
    bit_errors = int(np.count_nonzero(rx_bits != tx_bits))
    error = received[:size] - transmitted[:size]
    reference_rms = float(np.sqrt(np.mean(transmitted[:size] ** 2)))
    evm = float(np.sqrt(np.mean(error**2)) / reference_rms) if reference_rms else float("nan")
    return {
        "symbols_compared": size,
        "bits_compared": int(rx_bits.size),
        "symbol_errors": symbol_errors,
        "bit_errors": bit_errors,
        "ser": symbol_errors / size if size else float("nan"),
        "pre_fec_ber": bit_errors / rx_bits.size if rx_bits.size else float("nan"),
        "evm_rms": evm,
    }


def pam4_eye_metrics(received: FloatArray, transmitted: FloatArray) -> dict[str, Any]:
    size = min(received.size, transmitted.size)
    rx = received[:size]
    tx_indices = pam4_decisions(transmitted[:size])
    level_stats: list[dict[str, float | int]] = []
    clusters: list[FloatArray] = []
    for level_index in range(4):
        cluster = rx[tx_indices == level_index]
        clusters.append(cluster)
        if cluster.size:
            level_stats.append(
                {
                    "level_index": level_index,
                    "count": int(cluster.size),
                    "mean": float(np.mean(cluster)),
                    "std": float(np.std(cluster)),
                    "p01": float(np.percentile(cluster, 1.0)),
                    "p99": float(np.percentile(cluster, 99.0)),
                }
            )
        else:
            level_stats.append(
                {"level_index": level_index, "count": 0, "mean": float("nan"), "std": float("nan"), "p01": float("nan"), "p99": float("nan")}
            )
    openings = []
    for eye_index in range(3):
        lower = clusters[eye_index]
        upper = clusters[eye_index + 1]
        opening = (
            float(np.percentile(upper, 1.0) - np.percentile(lower, 99.0))
            if lower.size and upper.size
            else float("nan")
        )
        openings.append({"eye_index": eye_index, "vertical_opening_p01_p99": opening})
    return {"levels": level_stats, "eyes": openings}


def standard_comparison(
    profile_status: str,
    limits: dict[str, Any],
    measured: dict[str, Any],
    standard_overrides: tuple[str, ...],
) -> dict[str, Any]:
    checks: dict[str, Any] = {}
    if "pre_fec_ber_max" in limits:
        value = measured["pre_fec_ber"]
        checks["pre_fec_ber"] = {
            "value": value,
            "limit_max": limits["pre_fec_ber_max"],
            "status": "pass" if value <= limits["pre_fec_ber_max"] else "fail",
        }
    if "channel_loss_db_max" in limits and "channel_loss_db" in measured:
        value = measured["channel_loss_db"]
        checks["channel_loss_db"] = {
            "value": value,
            "limit_max": limits["channel_loss_db_max"],
            "status": "pass" if value <= limits["channel_loss_db_max"] else "fail",
        }
    if (
        "dispersion_ps_nm_min" in limits
        and "dispersion_ps_nm_max" in limits
        and "total_dispersion_ps_nm" in measured
    ):
        value = measured["total_dispersion_ps_nm"]
        lower = limits["dispersion_ps_nm_min"]
        upper = limits["dispersion_ps_nm_max"]
        checks["total_dispersion_ps_nm"] = {
            "value": value,
            "limit_min": lower,
            "limit_max": upper,
            "status": "pass" if lower <= value <= upper else "fail",
        }
    for name in ("tdecq_db", "tecq_db", "secq_db"):
        limit_name = f"{name}_max"
        if limit_name in limits:
            checks[name] = {
                "status": "not_evaluated",
                "limit_max": limits[limit_name],
                "reason": "reference measurement algorithm is scheduled for a later milestone",
            }
    claim = "engineering_only"
    if profile_status == "normative" and not standard_overrides:
        claim = "partial_standard_check"
    elif profile_status == "draft" and not standard_overrides:
        claim = "draft_baseline_check"
    return {
        "claim": claim,
        "profile_status": profile_status,
        "standard_overrides": list(standard_overrides),
        "checks": checks,
    }
