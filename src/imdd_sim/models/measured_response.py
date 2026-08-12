"""Measured electrical S21 import and frequency-domain filtering.

The model deliberately consumes only the forward transfer function S21.  It does
not solve source/load mismatch from S11/S22; use a circuit simulator first when
that interaction is important and export the resulting loaded S21.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import numpy as np
from numpy.typing import NDArray

from ..config import MeasuredS21Config

FloatArray = NDArray[np.float64]
ComplexArray = NDArray[np.complex128]

_FREQUENCY_SCALE = {"hz": 1.0, "khz": 1e3, "mhz": 1e6, "ghz": 1e9}


@dataclass(frozen=True)
class MeasuredResponse:
    """One-sided measured complex transfer function."""

    frequency_hz: FloatArray
    s21: ComplexArray
    source_format: str


def _pair_to_complex(first: FloatArray, second: FloatArray, data_format: str) -> ComplexArray:
    if data_format == "ri":
        return (first + 1j * second).astype(np.complex128)
    phase = np.deg2rad(second)
    magnitude = 10.0 ** (first / 20.0) if data_format == "db" else first
    return (magnitude * np.exp(1j * phase)).astype(np.complex128)


def _load_touchstone(path: Path) -> MeasuredResponse:
    """Read S21 from a Touchstone 1.x two-port file (RI, MA, or DB)."""
    if path.suffix.lower() != ".s2p":
        raise ValueError("measured S21 Touchstone input must be a two-port .s2p file")
    frequency_unit = "ghz"
    parameter = "s"
    data_format = "ma"
    numeric_tokens: list[float] = []
    with path.open("r", encoding="utf-8-sig") as stream:
        for raw_line in stream:
            line = raw_line.split("!", 1)[0].strip()
            if not line:
                continue
            if line.startswith("#"):
                options = line[1:].lower().split()
                if options:
                    frequency_unit = options[0]
                if len(options) >= 2:
                    parameter = options[1]
                if len(options) >= 3:
                    data_format = options[2]
                continue
            if line.startswith("["):
                raise ValueError("Touchstone 2.0 keyword files are not supported yet")
            try:
                numeric_tokens.extend(float(token.replace("D", "E").replace("d", "e")) for token in line.split())
            except ValueError as exc:
                raise ValueError(f"invalid numeric data in Touchstone file {path}") from exc
    if parameter != "s" or data_format not in {"ri", "ma", "db"}:
        raise ValueError("Touchstone input must contain S parameters in RI, MA, or DB format")
    if frequency_unit not in _FREQUENCY_SCALE:
        raise ValueError(f"unsupported Touchstone frequency unit {frequency_unit!r}")
    if not numeric_tokens or len(numeric_tokens) % 9:
        raise ValueError("Touchstone .s2p data must contain 9 values per frequency point")
    rows = np.asarray(numeric_tokens, dtype=np.float64).reshape(-1, 9)
    frequency_hz = rows[:, 0] * _FREQUENCY_SCALE[frequency_unit]
    # Touchstone two-port order is S11, S21, S12, S22.
    s21 = _pair_to_complex(rows[:, 3], rows[:, 4], data_format)
    return _clean_response(frequency_hz, s21, "touchstone")


def _normalized_header(name: str) -> str:
    return "".join(character for character in name.strip().lower() if character.isalnum() or character == "_")


def _find_column(headers: list[str], candidates: tuple[str, ...], required: bool) -> int | None:
    normalized = [_normalized_header(header) for header in headers]
    for candidate in candidates:
        if candidate in normalized:
            return normalized.index(candidate)
    if required:
        raise ValueError(f"CSV is missing one of the required columns: {candidates}")
    return None


def _load_csv(path: Path, config: MeasuredS21Config) -> MeasuredResponse:
    """Read frequency, S21 magnitude, and optional phase from a CSV file."""
    with path.open("r", encoding="utf-8-sig", newline="") as stream:
        rows = list(csv.reader(line for line in stream if line.strip() and not line.lstrip().startswith("#")))
    if len(rows) < 2:
        raise ValueError("measured S21 CSV must contain a header and at least one data row")
    headers = rows[0]
    frequency_index = _find_column(
        headers,
        ("frequency_hz", "frequency_khz", "frequency_mhz", "frequency_ghz", "freq_hz", "freq_ghz", "frequency", "freq"),
        True,
    )
    magnitude_index = _find_column(
        headers,
        ("magnitude_db", "mag_db", "s21_db", "magnitude_linear", "mag_linear", "s21_linear", "magnitude", "mag"),
        True,
    )
    phase_index = _find_column(
        headers,
        ("phase_deg", "s21_phase_deg", "phase_rad", "s21_phase_rad", "phase"),
        False,
    )
    try:
        values = np.asarray(
            [[float(row[frequency_index]), float(row[magnitude_index]), float(row[phase_index]) if phase_index is not None else 0.0] for row in rows[1:] if row],
            dtype=np.float64,
        )
    except (ValueError, IndexError) as exc:
        raise ValueError(f"invalid measured S21 CSV data in {path}") from exc
    unit = config.frequency_unit
    frequency_header = _normalized_header(headers[frequency_index])
    if unit == "auto":
        unit = next((item for item in ("ghz", "mhz", "khz", "hz") if frequency_header.endswith(item)), "hz")
    magnitude_format = "linear" if "linear" in _normalized_header(headers[magnitude_index]) else config.magnitude_format
    phase_unit = "rad" if phase_index is not None and "rad" in _normalized_header(headers[phase_index]) else config.phase_unit
    frequency_hz = values[:, 0] * _FREQUENCY_SCALE[unit]
    magnitude = 10.0 ** (values[:, 1] / 20.0) if magnitude_format == "db" else values[:, 1]
    phase = values[:, 2] if phase_unit == "rad" else np.deg2rad(values[:, 2])
    return _clean_response(frequency_hz, magnitude * np.exp(1j * phase), "csv")


def _clean_response(frequency_hz: FloatArray, s21: ComplexArray, source_format: str) -> MeasuredResponse:
    finite = np.isfinite(frequency_hz) & np.isfinite(s21.real) & np.isfinite(s21.imag)
    frequency_hz = np.asarray(frequency_hz[finite], dtype=np.float64)
    s21 = np.asarray(s21[finite], dtype=np.complex128)
    if frequency_hz.size < 2:
        raise ValueError("measured S21 requires at least two finite frequency points")
    order = np.argsort(frequency_hz)
    frequency_hz, s21 = frequency_hz[order], s21[order]
    unique, indices = np.unique(frequency_hz, return_index=True)
    s21 = s21[indices]
    if unique[0] < 0:
        raise ValueError("measured S21 frequencies must be non-negative")
    return MeasuredResponse(unique, s21, source_format)


@lru_cache(maxsize=32)
def _load_measured_s21_cached(
    path_text: str,
    modified_time_ns: int,
    file_format: str,
    frequency_unit: str,
    magnitude_format: str,
    phase_unit: str,
) -> MeasuredResponse:
    """Cache parsed VNA data across WDM lanes and Monte Carlo trials.

    ``modified_time_ns`` is part of the key so editing a measurement invalidates
    the cached response without requiring a Python process restart.
    """
    del modified_time_ns  # Used only as an automatic cache-invalidation key.
    path = Path(path_text)
    parse_config = MeasuredS21Config(
        path=path_text,
        file_format=file_format,
        frequency_unit=frequency_unit,
        magnitude_format=magnitude_format,
        phase_unit=phase_unit,
    )
    if file_format == "auto":
        file_format = "touchstone" if path.suffix.lower() == ".s2p" else "csv"
    return _load_touchstone(path) if file_format == "touchstone" else _load_csv(path, parse_config)


def load_measured_s21(config: MeasuredS21Config) -> MeasuredResponse:
    """Load the response selected by ``config.file_format``."""
    path = Path(config.path).resolve()
    if not path.is_file():
        raise ValueError(f"measured S21 file does not exist: {path}")
    return _load_measured_s21_cached(
        str(path),
        path.stat().st_mtime_ns,
        config.file_format,
        config.frequency_unit,
        config.magnitude_format,
        config.phase_unit,
    )


def apply_measured_s21(
    signal: FloatArray,
    sample_rate_hz: float,
    config: MeasuredS21Config,
) -> tuple[FloatArray, dict[str, float | str | bool]]:
    """Filter a real waveform by an interpolated complex measured response."""
    response = load_measured_s21(config)
    measured_frequency = response.frequency_hz
    magnitude = np.abs(response.s21)
    phase = np.unwrap(np.angle(response.s21))
    removed_delay_s = 0.0
    if config.remove_delay and measured_frequency.size >= 2:
        phase_slope, _ = np.polyfit(measured_frequency, phase, 1)
        phase = phase - phase_slope * measured_frequency
        removed_delay_s = -phase_slope / (2.0 * np.pi)

    fft_frequency = np.fft.rfftfreq(signal.size, d=1.0 / sample_rate_hz)
    if config.extrapolation == "hold":
        fft_magnitude = np.interp(fft_frequency, measured_frequency, magnitude)
    else:
        fft_magnitude = np.interp(fft_frequency, measured_frequency, magnitude, left=0.0, right=0.0)
    fft_phase = np.interp(fft_frequency, measured_frequency, phase, left=0.0, right=phase[-1])
    transfer = fft_magnitude * np.exp(1j * fft_phase)
    if config.normalize_dc and abs(transfer[0]) > np.finfo(float).eps:
        transfer = transfer / abs(transfer[0])
    # A real impulse response requires real-valued DC and Nyquist bins.
    transfer[0] = transfer[0].real
    if signal.size % 2 == 0:
        transfer[-1] = transfer[-1].real
    filtered = np.fft.irfft(np.fft.rfft(signal) * transfer, n=signal.size).real
    in_band = measured_frequency <= sample_rate_hz / 2.0
    minimum_db = float(20.0 * np.log10(max(np.min(magnitude[in_band]) if np.any(in_band) else np.min(magnitude), np.finfo(float).tiny)))
    return filtered.astype(np.float64), {
        "enabled": True,
        "path": str(Path(config.path)),
        "source_format": response.source_format,
        "points": int(measured_frequency.size),
        "minimum_frequency_hz": float(measured_frequency[0]),
        "maximum_frequency_hz": float(measured_frequency[-1]),
        "minimum_in_band_s21_db": minimum_db,
        "normalize_dc": config.normalize_dc,
        "remove_delay": config.remove_delay,
        "removed_delay_s": float(removed_delay_s),
        "replace_ideal_bandwidth": config.replace_ideal_bandwidth,
    }
