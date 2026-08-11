"""Mueller-Muller timing recovery with an interpolating ADC clock model."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.typing import NDArray

FloatArray = NDArray[np.float64]


@dataclass(frozen=True)
class TimingRecoveryResult:
    samples: FloatArray
    timing_error: FloatArray
    omega_history: FloatArray
    sample_positions: FloatArray
    locked: bool


def _slice_pam4(value: float) -> float:
    if value < -2.0:
        return -3.0
    if value < 0.0:
        return -1.0
    if value < 2.0:
        return 1.0
    return 3.0


def _sinc_sample(signal: FloatArray, position: float, half_span: int = 8) -> float:
    """Windowed-sinc fractional interpolator for low-oversampling ADC streams."""
    center = int(np.floor(position))
    start = center - half_span + 1
    stop = center + half_span + 1
    if start < 0 or stop > signal.size:
        raise IndexError(position)
    indices = np.arange(start, stop, dtype=np.float64)
    weights = np.sinc(position - indices) * np.hamming(indices.size)
    weight_sum = np.sum(weights)
    if abs(weight_sum) > np.finfo(float).eps:
        weights /= weight_sum
    return float(np.dot(signal[start:stop], weights))


def mueller_muller_recover(
    signal: FloatArray,
    nominal_sps: float,
    *,
    gain_mu: float = 0.01,
    gain_omega: float = 0.0001,
    max_clock_offset_ppm: float = 300.0,
    initial_phase_samples: float = 0.0,
) -> TimingRecoveryResult:
    """Recover one sample/symbol and feed phase/frequency error to a digital ADC clock.

    The phase accumulator and interpolator are an equivalent model of a variable-rate
    ADC sampling clock. ``omega_history`` exposes the commanded sample period.
    """
    if nominal_sps < 1.0:
        raise ValueError("nominal_sps must be at least one")
    if signal.size < 16:
        raise ValueError("signal is too short for timing recovery")
    maximum_delta = nominal_sps * max_clock_offset_ppm * 1e-6
    omega_min = nominal_sps - maximum_delta
    omega_max = nominal_sps + maximum_delta
    omega = nominal_sps
    oversampling_margin = min(max(nominal_sps - 1.0, 0.0), 1.0)
    effective_gain_mu = gain_mu * max(oversampling_margin**3, 1e-3)
    effective_gain_omega = gain_omega * max(oversampling_margin**4, 1e-4)
    interpolation_half_span = 8
    first_symbol_position = (
        np.ceil(interpolation_half_span / nominal_sps) * nominal_sps
        + initial_phase_samples
    )
    position = max(float(interpolation_half_span), float(first_symbol_position))

    outputs: list[float] = []
    errors: list[float] = []
    omegas: list[float] = []
    positions: list[float] = []
    previous_sample: float | None = None
    previous_decision: float | None = None
    loop_error = 0.0

    while position + interpolation_half_span + 1 < signal.size:
        sample = _sinc_sample(signal, position, interpolation_half_span)
        decision = _slice_pam4(sample)
        if previous_sample is None:
            error = 0.0
        else:
            error = previous_decision * sample - decision * previous_sample
            error = float(np.clip(error, -4.0, 4.0))
        # The TED output is data dependent; the loop filter suppresses symbol-rate
        # self-noise before commanding the equivalent ADC phase/frequency clock.
        loop_error = 0.98 * loop_error + 0.02 * error
        omega = float(
            np.clip(omega + effective_gain_omega * loop_error, omega_min, omega_max)
        )
        phase_correction = effective_gain_mu * loop_error
        outputs.append(sample)
        errors.append(error)
        omegas.append(omega)
        positions.append(position)
        position += omega + phase_correction
        previous_sample = sample
        previous_decision = decision

    error_array = np.asarray(errors, dtype=np.float64)
    tail = error_array[-min(256, error_array.size) :]
    locked = bool(tail.size and np.std(tail) < 2.0)
    return TimingRecoveryResult(
        samples=np.asarray(outputs, dtype=np.float64),
        timing_error=error_array,
        omega_history=np.asarray(omegas, dtype=np.float64),
        sample_positions=np.asarray(positions, dtype=np.float64),
        locked=locked,
    )
