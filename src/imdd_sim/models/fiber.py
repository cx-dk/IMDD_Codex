"""Linear and optional nonlinear single-/multi-channel fiber propagation."""

from __future__ import annotations

import numpy as np
from numpy.typing import NDArray

ComplexArray = NDArray[np.complex128]

_C_M_S = 299_792_458.0


def dispersion_to_beta2(
    dispersion_ps_nm_km: float,
    wavelength_nm: float,
) -> float:
    dispersion_si = dispersion_ps_nm_km * 1e-6  # s / m^2
    wavelength_m = wavelength_nm * 1e-9
    return -(dispersion_si * wavelength_m**2) / (2.0 * np.pi * _C_M_S)


def _linear_operator(
    sample_count: int,
    sample_rate_hz: float,
    length_m: float,
    attenuation_db_km: float,
    dispersion_ps_nm_km: float,
    wavelength_nm: float,
) -> ComplexArray:
    frequencies_hz = np.fft.fftfreq(sample_count, d=1.0 / sample_rate_hz)
    omega = 2.0 * np.pi * frequencies_hz
    beta2 = dispersion_to_beta2(dispersion_ps_nm_km, wavelength_nm)
    amplitude_loss = 10.0 ** (-(attenuation_db_km * length_m / 1000.0) / 20.0)
    return amplitude_loss * np.exp(-0.5j * beta2 * omega**2 * length_m)


def propagate_fiber(
    field: ComplexArray,
    *,
    sample_rate_hz: float,
    length_m: float,
    attenuation_db_km: float,
    dispersion_ps_nm_km: float,
    wavelength_nm: float,
    nonlinear_enabled: bool = False,
    gamma_w_inv_km: float = 1.3,
    ssfm_steps: int = 8,
) -> ComplexArray:
    if length_m <= 0:
        return field.copy()
    if not nonlinear_enabled:
        operator = _linear_operator(
            field.size,
            sample_rate_hz,
            length_m,
            attenuation_db_km,
            dispersion_ps_nm_km,
            wavelength_nm,
        )
        return np.fft.ifft(np.fft.fft(field) * operator)

    steps = max(1, int(ssfm_steps))
    dz_m = length_m / steps
    half_step = _linear_operator(
        field.size,
        sample_rate_hz,
        dz_m / 2.0,
        attenuation_db_km,
        dispersion_ps_nm_km,
        wavelength_nm,
    )
    gamma_w_inv_m = gamma_w_inv_km / 1000.0
    result = field.astype(np.complex128, copy=True)
    for _ in range(steps):
        result = np.fft.ifft(np.fft.fft(result) * half_step)
        result *= np.exp(1j * gamma_w_inv_m * dz_m * np.abs(result) ** 2)
        result = np.fft.ifft(np.fft.fft(result) * half_step)
    return result


def propagate_wdm_channels(
    fields: ComplexArray,
    *,
    sample_rate_hz: float,
    length_m: float,
    attenuation_db_km: float,
    dispersion_ps_nm_km: float,
    wavelengths_nm: tuple[float, ...],
    nonlinear_enabled: bool,
    gamma_w_inv_km: float,
    ssfm_steps: int,
    xpm_enabled: bool = True,
) -> ComplexArray:
    """Batch WDM propagation.

    Linear propagation uses batched FFTs. Nonlinear propagation implements efficient
    coupled-envelope SPM/XPM; full wideband FWM is intentionally deferred.
    """
    if fields.ndim != 2 or fields.shape[0] != len(wavelengths_nm):
        raise ValueError("fields must have shape (channel_count, sample_count)")
    result = fields.astype(np.complex128, copy=True)
    if not nonlinear_enabled:
        for index, wavelength in enumerate(wavelengths_nm):
            result[index] = propagate_fiber(
                result[index],
                sample_rate_hz=sample_rate_hz,
                length_m=length_m,
                attenuation_db_km=attenuation_db_km,
                dispersion_ps_nm_km=dispersion_ps_nm_km,
                wavelength_nm=wavelength,
            )
        return result

    steps = max(1, int(ssfm_steps))
    dz_m = length_m / steps
    gamma = gamma_w_inv_km / 1000.0
    half_steps = [
        _linear_operator(
            fields.shape[1],
            sample_rate_hz,
            dz_m / 2.0,
            attenuation_db_km,
            dispersion_ps_nm_km,
            wavelength,
        )
        for wavelength in wavelengths_nm
    ]
    for _ in range(steps):
        for channel, operator in enumerate(half_steps):
            result[channel] = np.fft.ifft(np.fft.fft(result[channel]) * operator)
        powers = np.abs(result) ** 2
        total_power = np.sum(powers, axis=0)
        for channel in range(result.shape[0]):
            nonlinear_power = powers[channel]
            if xpm_enabled:
                nonlinear_power = 2.0 * total_power - powers[channel]
            result[channel] *= np.exp(1j * gamma * dz_m * nonlinear_power)
        for channel, operator in enumerate(half_steps):
            result[channel] = np.fft.ifft(np.fft.fft(result[channel]) * operator)
    return result

