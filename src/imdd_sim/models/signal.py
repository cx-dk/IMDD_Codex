"""IEEE PAM4 test patterns, mapping, resampling, and electrical filtering.

The standard pattern definitions mirror ``julia/src/IMDDPatterns.jl``.  Register
bit ``i`` is IEEE register stage ``Si`` (S0 is the integer seed LSB), and ordered
bit pairs use the Clause 120 Gray mapping ``00, 01, 11, 10 -> 0, 1, 2, 3``.
"""

from __future__ import annotations

from functools import lru_cache
import re

import numpy as np
from numpy.typing import NDArray

FloatArray = NDArray[np.float64]
BitArray = NDArray[np.uint8]
CodeArray = NDArray[np.uint8]

# Taps are zero-based register stages S0...S(order-1). Feedback enters S0 and
# the old Si moves to S(i+1), matching the Julia reference branch exactly.
PRBS_FEEDBACK_TAPS: dict[int, tuple[int, ...]] = {
    7: (5, 6),  # 1 + x^6 + x^7
    9: (4, 8),  # 1 + x^5 + x^9; IEEE 802.3 Table 68-6
    13: (0, 1, 11, 12),  # 1 + x + x^2 + x^12 + x^13; Figure 94-6
    15: (13, 14),  # 1 + x^14 + x^15
    31: (27, 30),  # 1 + x^28 + x^31; Figure 49-9
}

SSPRQ_PERIOD_SYMBOLS = 65_535
SSPRQ_SECTIONS = (
    (0x00000002, 10_924),
    (0x34013FF7, 10_922),
    (0x0CCCCCCC, 10_922),
)

PAM4_CODES = np.array([0, 1, 2, 3], dtype=np.uint8)
PAM4_LEVELS = np.array([-3.0, -1.0, 1.0, 3.0], dtype=np.float64)
PAM4_NORMALIZED_LEVELS = PAM4_LEVELS / 3.0
PAM4_DECISION_THRESHOLDS = np.array([-2.0, 0.0, 2.0], dtype=np.float64)


def supported_patterns() -> tuple[str, ...]:
    """Return standard and engineering pattern names accepted by ``pattern_bits``."""
    return (
        "prbs7",
        "prbs9",
        "prbs13",
        "prbs13q",
        "prbs15",
        "prbs31",
        "prbs31q",
        "ssprq",
        "random",
        "zeros",
        "ones",
        "alternating",
        "pam4_cycle",
        "custom",
    )


def pattern_catalog() -> tuple[dict[str, str | bool], ...]:
    """Describe selectable patterns and the standard claim allowed for each."""
    references = {
        "prbs9": "IEEE 802.3-2022 Table 68-6",
        "prbs13": "IEEE 802.3-2022 Figure 94-6",
        "prbs13q": "IEEE 802.3-2022 120.5.11.2.1",
        "prbs31": "IEEE 802.3-2022 Figure 49-9",
        "prbs31q": "IEEE 802.3-2022 120.5.11.2.2",
        "ssprq": "IEEE 802.3-2022 120.5.11.2.3 and Table 120-2",
    }
    return tuple(
        {
            "name": name,
            "standard_test_pattern": name in references,
            "reference": references.get(name, "engineering stimulus"),
        }
        for name in supported_patterns()
    )


def pattern_metadata(pattern: str) -> dict[str, str | bool]:
    """Return catalog metadata for a normalized configured pattern name."""
    name = _normalized_pattern_name(pattern)
    for item in pattern_catalog():
        if item["name"] == name:
            return dict(item)
    raise ValueError(f"unsupported pattern {pattern!r}")


def _feedback_bit(state: int, taps: tuple[int, ...]) -> int:
    feedback = 0
    for tap in taps:
        feedback ^= (state >> tap) & 1
    return feedback


def generate_prbs(order: int, bit_count: int, seed: int = 1) -> BitArray:
    """Generate an IEEE-oriented PRBS bit stream using the named polynomial.

    The seed LSB presets S0. It must be non-zero and fit in the selected register;
    invalid seeds are rejected instead of being silently masked. PRBS31 emits the
    inverted feedback output specified by IEEE 802.3 Figure 49-9.
    """
    if order not in PRBS_FEEDBACK_TAPS:
        raise ValueError(
            f"unsupported PRBS order {order}; choose {sorted(PRBS_FEEDBACK_TAPS)}"
        )
    if bit_count < 1:
        raise ValueError("bit_count must be positive")
    mask = (1 << order) - 1
    if not 0 < seed <= mask:
        raise ValueError(f"seed must be in 1:{mask} for PRBS{order}")

    state = int(seed)
    taps = PRBS_FEEDBACK_TAPS[order]
    output = np.empty(bit_count, dtype=np.uint8)
    for index in range(bit_count):
        feedback = _feedback_bit(state, taps)
        output[index] = feedback ^ 1 if order == 31 else feedback
        state = ((state << 1) & mask) | feedback
    return output


def gray_map_pam4_codes(bits: BitArray) -> CodeArray:
    """Map ordered pairs ``00, 01, 11, 10`` to IEEE PAM4 codes ``0..3``."""
    raw_values = np.asarray(bits)
    if raw_values.ndim != 1 or raw_values.size % 2:
        raise ValueError("PAM4 mapping requires an even one-dimensional bit array")
    if not np.all(np.isin(raw_values, (0, 1))):
        raise ValueError("bits may contain only 0 and 1")
    values = raw_values.astype(np.uint8)
    pairs = values.reshape(-1, 2)
    binary_codes = (pairs[:, 0] << 1) | pairs[:, 1]
    # Indexed by ordered-pair binary value 00, 01, 10, 11.
    return np.array([0, 1, 3, 2], dtype=np.uint8)[binary_codes]


def gray_symbol_bits(symbol_codes: NDArray[np.integer]) -> BitArray:
    """Map IEEE PAM4 codes ``0,1,2,3`` back to ``00,01,11,10``."""
    codes = np.asarray(symbol_codes)
    if codes.ndim != 1 or np.any((codes < 0) | (codes > 3)):
        raise ValueError("PAM4 symbol codes must be a one-dimensional array in 0:3")
    pairs = np.array([[0, 0], [0, 1], [1, 1], [1, 0]], dtype=np.uint8)
    return pairs[codes.astype(np.int64)].reshape(-1)


def gray_map_pam4(bits: BitArray, *, normalize: bool = True) -> FloatArray:
    """Map bits to IEEE PAM4 levels, normalized to ``[-1, 1]`` by default."""
    levels = PAM4_LEVELS[gray_map_pam4_codes(bits)]
    return levels / 3.0 if normalize else levels.copy()


def gray_demap_pam4(level_indices: NDArray[np.integer]) -> BitArray:
    """Demap receiver decision indices ``0..3`` using the IEEE Gray pairing."""
    return gray_symbol_bits(level_indices)


def _repeat_to_length(base: NDArray, count: int) -> NDArray:
    if base.size == 0:
        raise ValueError("base sequence must not be empty")
    return np.resize(base, count)


@lru_cache(maxsize=1)
def _ssprq_symbol_period_cached() -> CodeArray:
    """Build IEEE 802.3-2022 120.5.11.2.3/Table 120-2 SSPRQ once."""
    sequence_a = np.concatenate(
        [generate_prbs(31, length, seed) for seed, length in SSPRQ_SECTIONS]
    )
    if sequence_a.size != 32_768:
        raise AssertionError("invalid SSPRQ sequence A length")

    repeated_a = np.concatenate((sequence_a, sequence_a))
    sequence_b = repeated_a[1:-1]
    sequence_1 = gray_map_pam4_codes(sequence_a)
    sequence_2 = 3 - gray_map_pam4_codes(sequence_a)
    sequence_3 = gray_map_pam4_codes(sequence_b[:32_766])
    sequence_4 = 3 - gray_map_pam4_codes(sequence_b[-32_768:])
    symbols = np.concatenate((sequence_1, sequence_2, sequence_3, sequence_4)).astype(
        np.uint8
    )
    if symbols.size != SSPRQ_PERIOD_SYMBOLS:
        raise AssertionError("invalid SSPRQ period length")
    symbols.flags.writeable = False
    return symbols


def ssprq_symbols(symbol_count: int = SSPRQ_PERIOD_SYMBOLS) -> CodeArray:
    """Return the fixed IEEE Clause 120 SSPRQ period, repeated or truncated."""
    if symbol_count < 1:
        raise ValueError("symbol_count must be positive")
    return _repeat_to_length(_ssprq_symbol_period_cached(), symbol_count).astype(np.uint8)


def _splitmix64_bits(bit_count: int, seed: int) -> BitArray:
    """Generate the same version-independent engineering random bits as Julia."""
    mask = (1 << 64) - 1
    state = seed & mask
    output = np.empty(bit_count, dtype=np.uint8)
    word = 0
    for index in range(bit_count):
        if index % 64 == 0:
            state = (state + 0x9E3779B97F4A7C15) & mask
            value = state
            value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & mask
            value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & mask
            word = (value ^ (value >> 31)) & mask
        output[index] = (word >> (index % 64)) & 1
    return output


def _normalized_pattern_name(pattern: str) -> str:
    return pattern.strip().lower().replace("-", "_").replace(" ", "_")


def pattern_bits(
    pattern: str,
    symbol_count: int,
    seed: int = 1,
    custom_bits: NDArray[np.integer] | None = None,
) -> BitArray:
    """Generate exactly two bits per PAM4 symbol.

    PRBS13Q, PRBS31Q and SSPRQ follow IEEE 802.3 Clause 120. Fixed/random/custom
    names are engineering stimuli and must not be presented as compliance tests.
    The SSPRQ sequence is fixed, so ``seed`` has no effect for that pattern.
    """
    if symbol_count < 1:
        raise ValueError("symbol_count must be positive")
    count = 2 * symbol_count
    name = _normalized_pattern_name(pattern)

    match = re.fullmatch(r"prbs(7|9|13|15|31)q?", name)
    if match and name in supported_patterns():
        return generate_prbs(int(match.group(1)), count, seed)
    if name == "ssprq":
        return gray_symbol_bits(ssprq_symbols(symbol_count))
    if name == "random":
        return _splitmix64_bits(count, seed)
    if name in {"zeros", "all_zeros", "all_zero"}:
        return np.zeros(count, dtype=np.uint8)
    if name in {"ones", "all_ones", "all_one"}:
        return np.ones(count, dtype=np.uint8)
    if name in {"alternating", "clock", "01"}:
        return _repeat_to_length(np.array([0, 1], dtype=np.uint8), count)
    if name in {"pam4_cycle", "level_cycle"}:
        return _repeat_to_length(
            np.array([0, 0, 0, 1, 1, 1, 1, 0], dtype=np.uint8), count
        )
    if name == "custom":
        if custom_bits is None:
            raise ValueError("custom_bits is required for the custom pattern")
        values = np.asarray(custom_bits, dtype=np.uint8)
        if values.ndim != 1 or values.size == 0 or np.any(values > 1):
            raise ValueError("custom_bits must be a non-empty one-dimensional bit array")
        return _repeat_to_length(values, count)
    raise ValueError(
        f"unsupported pattern {pattern!r}; choose one of {supported_patterns()}"
    )


def pattern_symbols(
    pattern: str,
    symbol_count: int,
    seed: int = 1,
    custom_bits: NDArray[np.integer] | None = None,
    *,
    normalize: bool = True,
) -> FloatArray:
    """Generate a named bit pattern and directly map it to IEEE PAM4 levels."""
    return gray_map_pam4(
        pattern_bits(pattern, symbol_count, seed, custom_bits),
        normalize=normalize,
    )


def pam4_decisions(samples: FloatArray) -> NDArray[np.int_]:
    """Hard-decide full-scale PAM4 samples near ``[-3,-1,+1,+3]`` to codes 0..3."""
    return np.digitize(samples, PAM4_DECISION_THRESHOLDS).astype(np.int64)


def normalized_pam4_levels(indices: NDArray[np.integer]) -> FloatArray:
    """Convert codes 0..3 to normalized levels ``[-1,-1/3,+1/3,+1]``."""
    return PAM4_NORMALIZED_LEVELS[np.asarray(indices, dtype=np.int64)]


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
    """Apply a zero-phase Butterworth-like low-pass response in the FFT domain."""
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
    """Robustly scale an analog PAM4 waveform toward full-scale levels ±3."""
    low, high = np.percentile(signal, [1.0, 99.0])
    span = high - low
    if span <= np.finfo(float).eps:
        return np.zeros_like(signal)
    midpoint = 0.5 * (high + low)
    return (signal - midpoint) * (6.0 / span)
