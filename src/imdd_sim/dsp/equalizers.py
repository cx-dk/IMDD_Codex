"""CPU-oriented FFE, DFE, and diagonal Volterra equalizers."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from numpy.typing import NDArray

FloatArray = NDArray[np.float64]


@dataclass(frozen=True)
class EqualizerResult:
    output: FloatArray
    reference: FloatArray
    coefficients: FloatArray
    training_mse: float


def _windows(signal: FloatArray, taps: int) -> FloatArray:
    if taps < 1 or signal.size < taps:
        raise ValueError("invalid tap count for signal length")
    return sliding_window_view(signal, taps).astype(np.float64)


def ffe_least_squares(
    signal: FloatArray,
    reference: FloatArray,
    taps: int,
    training_symbols: int,
) -> EqualizerResult:
    windows = _windows(signal, taps)
    center = taps // 2
    usable = min(windows.shape[0], reference.size - center)
    windows = windows[:usable]
    target = reference[center : center + usable]
    train = min(max(taps * 4, training_symbols), usable)
    coefficients, *_ = np.linalg.lstsq(windows[:train], target[:train], rcond=1e-6)
    output = windows @ coefficients
    mse = float(np.mean((output[:train] - target[:train]) ** 2))
    return EqualizerResult(output, target, coefficients.astype(np.float64), mse)


def _decision(value: float) -> float:
    return float(np.array([-3.0, -1.0, 1.0, 3.0])[np.argmin(np.abs(value - np.array([-3.0, -1.0, 1.0, 3.0])))])


def dfe_equalize(
    signal: FloatArray,
    reference: FloatArray,
    taps: int,
    training_symbols: int,
    step: float,
) -> EqualizerResult:
    feedback = np.zeros(taps, dtype=np.float64)
    output = np.empty_like(signal)
    decisions = np.zeros(taps, dtype=np.float64)
    errors = []
    for index, sample in enumerate(signal):
        value = float(sample - np.dot(feedback, decisions))
        desired = float(reference[index]) if index < min(training_symbols, reference.size) else _decision(value)
        error = desired - value
        feedback -= step * error * decisions
        output[index] = value
        decisions[1:] = decisions[:-1]
        decisions[0] = _decision(value)
        if index < training_symbols:
            errors.append(error * error)
    return EqualizerResult(
        output=output,
        reference=reference[: output.size],
        coefficients=feedback,
        training_mse=float(np.mean(errors)) if errors else 0.0,
    )


def volterra_ffe_equalize(
    signal: FloatArray,
    reference: FloatArray,
    memory: int,
    order: int,
    training_symbols: int,
) -> EqualizerResult:
    if order not in {2, 3}:
        raise ValueError("the MVP Volterra equalizer supports order 2 or 3")
    windows = _windows(signal, memory)
    center = memory // 2
    usable = min(windows.shape[0], reference.size - center)
    windows = windows[:usable]
    features = [windows, windows**2]
    if order == 3:
        features.append(windows**3)
    matrix = np.concatenate(features, axis=1)
    target = reference[center : center + usable]
    train = min(max(memory * order * 4, training_symbols), usable)
    coefficients, *_ = np.linalg.lstsq(matrix[:train], target[:train], rcond=1e-6)
    output = matrix @ coefficients
    mse = float(np.mean((output[:train] - target[:train]) ** 2))
    return EqualizerResult(output, target, coefficients.astype(np.float64), mse)

