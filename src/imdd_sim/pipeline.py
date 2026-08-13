"""End-to-end IMDD PAM4 simulation pipeline."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np
from numpy.typing import NDArray

from .config import PlatformConfig
from .dsp import (
    dfe_equalize,
    ffe_least_squares,
    mlse_detect,
    mueller_muller_recover,
    volterra_ffe_equalize,
)
from .metrics import (
    align_symbol_streams,
    error_metrics,
    pam4_eye_metrics,
    standard_comparison,
)
from .models.fiber import propagate_fiber, propagate_wdm_channels
from .models.measured_response import apply_measured_s21
from .models.optics import add_rin, cw_laser, eml_modulate, mzm_modulate
from .models.receiver import direct_detect, quantize_adc
from .models.signal import (
    agc_normalize_pam4,
    gray_map_pam4,
    gray_map_pam4_codes,
    lowpass_fft,
    oversample_symbols,
    pattern_bits,
    pattern_metadata,
    resample_linear,
)
from .profiles import get_profile
from .interfaces import get_electrical_interface, select_electrical_interface

FloatArray = NDArray[np.float64]
ComplexArray = NDArray[np.complex128]


@dataclass(frozen=True)
class SimulationResult:
    metadata: dict[str, Any]
    metrics: dict[str, Any]
    eye: dict[str, Any]
    dsp: dict[str, Any]
    standard: dict[str, Any]
    waveforms: dict[str, NDArray[Any]]

    def to_dict(self) -> dict[str, Any]:
        return {
            "metadata": self.metadata,
            "metrics": self.metrics,
            "eye": self.eye,
            "dsp": self.dsp,
            "standard": self.standard,
        }


def _make_optical_lane(
    config: PlatformConfig,
    wavelength_nm: float,
    pattern_seed: int,
    noise_seed: int,
) -> tuple[ComplexArray, FloatArray, NDArray[np.uint8], dict[str, Any]]:
    """Generate one PAM4 lane and convert its electrical drive to an optical field.

    A configured measured transmitter S21 is applied to the DAC/driver waveform.
    It either replaces the ideal electrical-bandwidth model or cascades with it.
    """
    rng = np.random.default_rng(noise_seed)
    symbol_rate_hz = config.symbol_rate_hz
    sample_rate_hz = symbol_rate_hz * config.simulation.tx_sps
    bits = pattern_bits(
        config.simulation.pattern,
        config.simulation.symbols,
        pattern_seed,
    )
    symbols = gray_map_pam4(bits)
    drive = oversample_symbols(symbols, config.simulation.tx_sps)
    measured = config.transmitter.measured_s21
    if not measured.enabled or not measured.replace_ideal_bandwidth:
        drive = lowpass_fft(
            drive,
            sample_rate_hz,
            config.transmitter.electrical_bandwidth_hz,
        )
    if measured.enabled:
        drive, response_info = apply_measured_s21(drive, sample_rate_hz, measured)
    else:
        response_info = {"enabled": False}
    laser = cw_laser(
        drive.size,
        sample_rate_hz,
        config.transmitter.laser.power_dbm,
        config.transmitter.laser.linewidth_hz,
        rng,
    )
    laser = add_rin(
        laser,
        sample_rate_hz,
        config.transmitter.laser.rin_db_hz,
        rng,
    )
    if config.transmitter.modulator == "mzm":
        field = mzm_modulate(
            laser,
            drive,
            config.transmitter.drive_vpp,
            config.transmitter.vpi_v,
            config.transmitter.bias_phase_rad,
            config.transmitter.chirp,
            extinction_ratio_db=config.transmitter.extinction_ratio_db,
        )
    else:
        field = eml_modulate(
            laser,
            drive,
            config.transmitter.extinction_ratio_db,
            config.transmitter.chirp,
        )
    return field, symbols, bits, response_info


def _propagate(
    fields: ComplexArray,
    wavelengths_nm: tuple[float, ...],
    config: PlatformConfig,
) -> ComplexArray:
    """Propagate one lane or a WDM batch through the configured fiber model."""
    sample_rate_hz = config.symbol_rate_hz * config.simulation.tx_sps
    kwargs = {
        "sample_rate_hz": sample_rate_hz,
        "length_m": config.fiber.length_m,
        "attenuation_db_km": config.fiber.attenuation_db_km,
        "dispersion_ps_nm_km": config.fiber.dispersion_ps_nm_km,
    }
    if fields.shape[0] == 1:
        propagated = propagate_fiber(
            fields[0],
            wavelength_nm=wavelengths_nm[0],
            nonlinear_enabled=config.fiber.nonlinear_enabled,
            gamma_w_inv_km=config.fiber.gamma_w_inv_km,
            ssfm_steps=config.fiber.ssfm_steps,
            **kwargs,
        )
        return propagated[None, :]
    return propagate_wdm_channels(
        fields,
        wavelengths_nm=wavelengths_nm,
        nonlinear_enabled=config.fiber.nonlinear_enabled,
        gamma_w_inv_km=config.fiber.gamma_w_inv_km,
        ssfm_steps=config.fiber.ssfm_steps,
        xpm_enabled=config.fiber.xpm_enabled,
        **kwargs,
    )


def run_simulation(config: PlatformConfig) -> SimulationResult:
    """Run a complete optical lane simulation and return metrics plus waveforms.

    Processing order is TX pattern/driver/modulator, fiber, PIN/TIA/ADC, timing
    recovery, trained equalization, optional DFE/MLSE, and finally BER/eye tests.
    """
    config.validate()
    profile = get_profile(config.profile)
    interface = (
        select_electrical_interface(
            config.architecture,
            float(profile.values["line_rate_gbps"]),
            profile.family,
        )
        if config.electrical_interface == "auto"
        else get_electrical_interface(config.electrical_interface)
    )
    wavelengths_nm = tuple(float(value) for value in profile.values["wavelengths_nm"])
    selected_lane = int(
        np.argmin(np.abs(np.asarray(wavelengths_nm) - config.transmitter.laser.wavelength_nm))
    )

    optical_fields = []
    transmitted_symbols = []
    transmitted_bits = []
    transmitter_responses = []
    for lane, wavelength in enumerate(wavelengths_nm):
        pattern_seed = (
            config.simulation.pattern_seed
            + config.simulation.pattern_lane_seed_stride * lane
        )
        field, symbols, bits, response_info = _make_optical_lane(
            config,
            wavelength,
            pattern_seed,
            config.simulation.seed + 1009 * lane,
        )
        optical_fields.append(field)
        transmitted_symbols.append(symbols)
        transmitted_bits.append(bits)
        transmitter_responses.append(response_info)
    tx_fields = np.stack(optical_fields)
    rx_fields = _propagate(tx_fields, wavelengths_nm, config)

    rng = np.random.default_rng(config.simulation.seed + 99991)
    sample_rate_hz = config.symbol_rate_hz * config.simulation.tx_sps
    analog = direct_detect(
        rx_fields[selected_lane],
        sample_rate_hz=sample_rate_hz,
        responsivity_a_w=config.receiver.responsivity_a_w,
        bandwidth_hz=config.receiver.bandwidth_hz,
        tia_gain_ohm=config.receiver.tia_gain_ohm,
        thermal_noise_a_sqrt_hz=config.receiver.thermal_noise_a_sqrt_hz,
        shot_noise_enabled=config.receiver.shot_noise_enabled,
        rng=rng,
        filter_enabled=not (
            config.receiver.measured_s21.enabled
            and config.receiver.measured_s21.replace_ideal_bandwidth
        ),
    )
    if config.receiver.measured_s21.enabled:
        analog, receiver_response = apply_measured_s21(
            analog,
            sample_rate_hz,
            config.receiver.measured_s21,
        )
    else:
        receiver_response = {"enabled": False}
    adc_full_rate = quantize_adc(
        analog,
        config.receiver.adc_bits,
        config.receiver.adc_full_scale_v,
    )
    actual_adc_sps = config.receiver.processing_sps * (
        1.0 + config.receiver.adc_clock_offset_ppm * 1e-6
    )
    adc = resample_linear(
        adc_full_rate,
        config.simulation.tx_sps,
        actual_adc_sps,
        config.receiver.adc_phase_ui,
    )
    adc_normalized = agc_normalize_pam4(adc)

    if config.dsp.timing.enabled:
        timing = mueller_muller_recover(
            adc_normalized,
            config.receiver.processing_sps,
            gain_mu=config.dsp.timing.gain_mu,
            gain_omega=config.dsp.timing.gain_omega,
            max_clock_offset_ppm=config.dsp.timing.max_clock_offset_ppm,
        )
        recovered = timing.samples
        timing_info = {
            "enabled": True,
            "locked": timing.locked,
            "mean_error": float(np.mean(timing.timing_error)),
            "rms_error": float(np.sqrt(np.mean(timing.timing_error**2))),
            "mean_omega_samples": float(np.mean(timing.omega_history)),
        }
    else:
        recovered = resample_linear(adc_normalized, config.receiver.processing_sps, 1.0)
        timing = None
        timing_info = {"enabled": False, "locked": None}

    recovered = agc_normalize_pam4(recovered)
    alignment = align_symbol_streams(recovered, transmitted_symbols[selected_lane])
    discard = config.simulation.discard_symbols
    stop = min(alignment.received.size, alignment.transmitted.size) - discard
    aligned_rx = alignment.received[discard:stop]
    aligned_tx = alignment.transmitted[discard:stop]
    if aligned_rx.size < max(256, config.dsp.ffe_taps * 8):
        raise RuntimeError("too few aligned symbols remain after transient removal")

    if config.dsp.volterra_enabled:
        equalizer = volterra_ffe_equalize(
            aligned_rx,
            aligned_tx,
            config.dsp.volterra_memory,
            config.dsp.volterra_order,
            config.dsp.training_symbols,
        )
        equalizer_name = "volterra_ffe"
    else:
        equalizer = ffe_least_squares(
            aligned_rx,
            aligned_tx,
            config.dsp.ffe_taps,
            config.dsp.training_symbols,
        )
        equalizer_name = "ffe"
    equalized = equalizer.output
    reference = equalizer.reference
    dfe_coefficients: FloatArray | None = None
    if config.dsp.dfe_enabled:
        dfe = dfe_equalize(
            equalized,
            reference,
            config.dsp.dfe_taps,
            config.dsp.training_symbols,
            config.dsp.dfe_step,
        )
        equalized = dfe.output
        reference = dfe.reference
        dfe_coefficients = dfe.coefficients

    if config.dsp.mlse_enabled:
        equalized = mlse_detect(
            equalized,
            np.asarray(config.dsp.mlse_channel_taps, dtype=np.float64),
        )

    measured = error_metrics(equalized, reference)
    measured.update(
        {
            "fiber_length_m": config.fiber.length_m,
            "channel_loss_db": config.fiber.attenuation_db_km
            * config.fiber.length_m
            / 1000.0,
            "total_dispersion_ps_nm": config.fiber.dispersion_ps_nm_km
            * config.fiber.length_m
            / 1000.0,
        }
    )
    eye = pam4_eye_metrics(equalized, reference)
    standard = standard_comparison(
        profile.status,
        dict(profile.limits),
        measured,
        config.standard_overrides,
    )
    dsp_info = {
        "timing": timing_info,
        "alignment": {
            "lag_symbols": alignment.lag,
            "polarity": alignment.polarity,
            "raw_ser": alignment.raw_ser,
        },
        "equalizer": {
            "type": equalizer_name,
            "coefficients": equalizer.coefficients.tolist(),
            "training_mse": equalizer.training_mse,
        },
        "dfe": {
            "enabled": config.dsp.dfe_enabled,
            "coefficients": dfe_coefficients.tolist() if dfe_coefficients is not None else [],
        },
        "mlse": {
            "enabled": config.dsp.mlse_enabled,
            "channel_taps": list(config.dsp.mlse_channel_taps),
        },
    }
    metadata = {
        "platform_version": "0.1.0",
        "profile": profile.as_dict(),
        "architecture": config.architecture,
        "electrical_interface": interface.as_dict(),
        "symbol_rate_hz": config.symbol_rate_hz,
        "tx_sps": config.simulation.tx_sps,
        "receiver_processing_sps": config.receiver.processing_sps,
        "adc_clock_offset_ppm": config.receiver.adc_clock_offset_ppm,
        "selected_wavelength_nm": wavelengths_nm[selected_lane],
        "wdm_channel_count": len(wavelengths_nm),
        "nonlinear_model": (
            "spm_xpm_coupled_envelope"
            if config.fiber.nonlinear_enabled and len(wavelengths_nm) > 1
            else "scalar_spm"
            if config.fiber.nonlinear_enabled
            else "disabled"
        ),
        "simulation_symbols": config.simulation.symbols,
        "seed": config.simulation.seed,
        "pattern": config.simulation.pattern,
        "pattern_definition": pattern_metadata(config.simulation.pattern),
        "pattern_seed": config.simulation.pattern_seed,
        "pattern_lane_seed_stride": config.simulation.pattern_lane_seed_stride,
        "measured_s21": {
            "transmitter": transmitter_responses[selected_lane],
            "receiver": receiver_response,
        },
    }
    waveforms: dict[str, NDArray[Any]] = {
        "tx_symbols": transmitted_symbols[selected_lane],
        "tx_symbol_codes": gray_map_pam4_codes(transmitted_bits[selected_lane]),
        "tx_bits": transmitted_bits[selected_lane],
        "tx_optical_power_w": np.abs(tx_fields[selected_lane]) ** 2,
        "rx_optical_power_w": np.abs(rx_fields[selected_lane]) ** 2,
        "rx_analog_v": analog,
        "adc": adc,
        "recovered_symbols": recovered,
        "equalized_symbols": equalized,
        "reference_symbols": reference,
    }
    if timing is not None:
        waveforms["timing_error"] = timing.timing_error
        waveforms["timing_omega"] = timing.omega_history
    return SimulationResult(metadata, measured, eye, dsp_info, standard, waveforms)
