"""PRBS, PAM4 mapping, resampling, and basic electrical filtering."""

from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

FloatArray = NDArray[np.float64]


_PRBS_TAPS = {
    7: (7, 6),
    9: (9, 5),
    13: (13, 12, 11, 8),
    15: (15, 14),
    31: (31, 28),
}


def generate_prbs(order: int, bit_count: int, seed: int = 1) -> NDArray[np.uint8]:
    """Generate a deterministic maximal-length style PRBS bit stream.

    The generator is intentionally streaming and does not materialize a full period.
    """
    if order not in _PRBS_TAPS:
        raise ValueError(f"unsupported PRBS order {order}; choose {sorted(_PRBS_TAPS)}")
    if bit_count < 1:
        raise ValueError("bit_count must be positive")
    mask = (1 << order) - 1
    state = seed & mask
    if state == 0:
        state = 1
    output = np.empty(bit_count, dtype=np.uint8)
    taps = _PRBS_TAPS[order]
    for index in range(bit_count):
        output[index] = state & 1
        feedback = 0
        for tap in taps:
            feedback ^= (state >> (order - tap)) & 1
        state = ((state >> 1) | (feedback << (order - 1))) & mask
    return output


def pattern_bits(pattern: str, symbol_count: int, seed: int) -> NDArray[np.uint8]:
    name = pattern.lower()
    if name in {"prbs13q", "prbs13"}:
        return generate_prbs(13, symbol_count * 2, seed)
    if name in {"prbs31q", "prbs31"}:
        return generate_prbs(31, symbol_count * 2, seed)
    if name == "ssprq":
        base = np.array(
            [0, 0, 0, 0, 1, 1, 1, 1, 0, 1, 1, 0, 1, 0, 0, 1],
            dtype=np.uint8,
        )
        return np.resize(base, symbol_count * 2)
    if name == "random":
        rng = np.random.default_rng(seed)
        return rng.integers(0, 2, symbol_count * 2, dtype=np.uint8)
    raise ValueError(f"unsupported pattern {pattern!r}")


def gray_map_pam4(bits: NDArray[np.uint8]) -> FloatArray:
    """Map Gray pairs 00, 01, 11, 10 to normalized PAM4 levels."""
    if bits.size % 2:
        raise ValueError("PAM4 mapping requires an even number of bits")
    pairs = bits.reshape(-1, 2)
    codes = (pairs[:, 0] << 1) | pairs[:, 1]
    levels = np.array([-3.0, -1.0, 3.0, 1.0], dtype=np.float64)
    return levels[codes] / 3.0


def gray_demap_pam4(level_indices: NDArray[np.int_]) -> NDArray[np.uint8]:
    bit_pairs = np.array([[0, 0], [0, 1], [1, 0], [1, 1]], dtype=np.uint8)
    # Decision indices 0,1,2,3 correspond to levels -3,-1,+1,+3.
    code_for_level = np.array([0, 1, 3, 2], dtype=np.int64)
    return bit_pairs[code_for_level[level_indices]].reshape(-1)


def pam4_decisions(samples: FloatArray) -> NDArray[np.int_]:
    thresholds = np.array([-2.0, 0.0, 2.0])
    return np.digitize(samples, thresholds).astype(np.int64)


def normalized_pam4_levels(indices: NDArray[np.int_]) -> FloatArray:
    return np.array([-3.0, -1.0, 1.0, 3.0], dtype=np.float64)[indices]


def oversample_symbols(symbols: FloatArray, samples_per_symbol: int) -> FloatArray:
    if samples_per_symbol < 1:
        raise ValueError("samples_per_symbol must be positive")
    return np.repeat(symbols, samples_per_symbol).astype(np.float64)


def lowpass_fft(
    signal: FloatArray,
    sample_rate_hz: float,
    bandwidth_hz: float,
    order: int = 4,
) -> FloatArray:
    """Zero-phase Butterworth-like low-pass response in the frequency domain."""
    if bandwidth_hz <= 0 or bandwidth_hz >= sample_rate_hz / 2:
        return signal.astype(np.float64, copy=True)
    frequencies = np.fft.rfftfreq(signal.size, d=1.0 / sample_rate_hz)
    response = 1.0 / np.sqrt(1.0 + (frequencies / bandwidth_hz) ** (2 * order))
    return np.fft.irfft(np.fft.rfft(signal) * response, n=signal.size).real


def resample_linear(
    signal: FloatArray,
    source_sps: float,
    target_sps: float,
    phase_ui: float = 0.0,
) -> FloatArray:
    """Cross-platform fractional resampler using linear interpolation."""
    if source_sps <= 0 or target_sps <= 0:
        raise ValueError("samples per symbol must be positive")
    symbol_extent = (signal.size - 1) / source_sps
    target_times = np.arange(phase_ui, symbol_extent, 1.0 / target_sps)
    source_times = np.arange(signal.size) / source_sps
    return np.interp(target_times, source_times, signal).astype(np.float64)


def agc_normalize_pam4(signal: FloatArray) -> FloatArray:
    low, high = np.percentile(signal, [1.0, 99.0])
    span = high - low
    if span <= np.finfo(float).eps:
        return np.zeros_like(signal)
    midpoint = 0.5 * (high + low)
    return (signal - midpoint) * (6.0 / span)

