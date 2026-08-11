"""Laser, MZM, and EML behavioral models."""

from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

ComplexArray = NDArray[np.complex128]
FloatArray = NDArray[np.float64]


def dbm_to_watts(power_dbm: float) -> float:
    return 1e-3 * 10.0 ** (power_dbm / 10.0)


def cw_laser(
    sample_count: int,
    sample_rate_hz: float,
    power_dbm: float,
    linewidth_hz: float,
    rng: np.random.Generator,
) -> ComplexArray:
    power_w = dbm_to_watts(power_dbm)
    if linewidth_hz <= 0:
        return np.full(sample_count, np.sqrt(power_w), dtype=np.complex128)
    phase_step_sigma = np.sqrt(2.0 * np.pi * linewidth_hz / sample_rate_hz)
    phase = np.cumsum(rng.normal(0.0, phase_step_sigma, sample_count))
    return np.sqrt(power_w) * np.exp(1j * phase)


def add_rin(
    field: ComplexArray,
    sample_rate_hz: float,
    rin_db_hz: float,
    rng: np.random.Generator,
) -> ComplexArray:
    """Apply white relative-intensity noise over the represented Nyquist band."""
    rin_linear_hz = 10.0 ** (rin_db_hz / 10.0)
    fractional_sigma = np.sqrt(max(rin_linear_hz * sample_rate_hz / 2.0, 0.0))
    fractional_power = np.clip(
        1.0 + rng.normal(0.0, fractional_sigma, field.size),
        0.0,
        None,
    )
    return (field * np.sqrt(fractional_power)).astype(np.complex128)


def mzm_modulate(
    laser_field: ComplexArray,
    drive: FloatArray,
    drive_vpp: float,
    vpi_v: float,
    bias_phase_rad: float,
    chirp: float = 0.0,
) -> ComplexArray:
    if vpi_v <= 0:
        raise ValueError("vpi_v must be positive")
    voltage = 0.5 * drive_vpp * drive
    phase = bias_phase_rad + np.pi * voltage / (2.0 * vpi_v)
    field = laser_field * np.cos(phase)
    if chirp:
        intensity = np.maximum(np.abs(field) ** 2, np.finfo(float).tiny)
        field = field * np.exp(0.5j * chirp * np.log(intensity / np.mean(intensity)))
    return field.astype(np.complex128)


def eml_modulate(
    laser_field: ComplexArray,
    drive: FloatArray,
    extinction_ratio_db: float,
    chirp: float = 0.0,
) -> ComplexArray:
    normalized = np.clip((drive + 1.0) / 2.0, 0.0, 1.0)
    minimum_power_ratio = 10.0 ** (-extinction_ratio_db / 10.0)
    transmission_power = minimum_power_ratio + (1.0 - minimum_power_ratio) * normalized
    amplitude = np.sqrt(transmission_power)
    phase = 0.5 * chirp * np.log(np.maximum(transmission_power, np.finfo(float).tiny))
    return (laser_field * amplitude * np.exp(1j * phase)).astype(np.complex128)
