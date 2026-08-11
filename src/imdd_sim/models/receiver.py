"""Direct-detection receiver and ADC models."""

from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

from .signal import lowpass_fft

ComplexArray = NDArray[np.complex128]
FloatArray = NDArray[np.float64]

_E_CHARGE_C = 1.602176634e-19


def direct_detect(
    field: ComplexArray,
    *,
    sample_rate_hz: float,
    responsivity_a_w: float,
    bandwidth_hz: float,
    tia_gain_ohm: float,
    thermal_noise_a_sqrt_hz: float,
    shot_noise_enabled: bool,
    rng: np.random.Generator,
) -> FloatArray:
    optical_power = np.abs(field) ** 2
    photocurrent = responsivity_a_w * optical_power
    noise_bandwidth = min(bandwidth_hz, sample_rate_hz / 2.0)
    thermal_sigma = thermal_noise_a_sqrt_hz * np.sqrt(noise_bandwidth)
    if shot_noise_enabled:
        shot_sigma = np.sqrt(
            np.maximum(2.0 * _E_CHARGE_C * photocurrent * noise_bandwidth, 0.0)
        )
    else:
        shot_sigma = np.zeros_like(photocurrent)
    current = photocurrent + rng.normal(0.0, 1.0, field.size) * np.sqrt(
        thermal_sigma**2 + shot_sigma**2
    )
    voltage = current * tia_gain_ohm
    return lowpass_fft(voltage, sample_rate_hz, bandwidth_hz)


def quantize_adc(signal: FloatArray, bits: int, full_scale_v: float) -> FloatArray:
    if bits < 1:
        raise ValueError("ADC bits must be positive")
    if full_scale_v <= 0:
        raise ValueError("ADC full scale must be positive")
    centered = signal - np.median(signal)
    peak = np.percentile(np.abs(centered), 99.9)
    if peak > 0:
        centered = centered * (0.45 * full_scale_v / peak)
    minimum = -0.5 * full_scale_v
    maximum = 0.5 * full_scale_v
    levels = 2**bits
    step = (maximum - minimum) / (levels - 1)
    clipped = np.clip(centered, minimum, maximum)
    return (np.round((clipped - minimum) / step) * step + minimum).astype(np.float64)

