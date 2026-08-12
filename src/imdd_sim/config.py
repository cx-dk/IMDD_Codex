"""Typed TOML configuration and validation.

The dataclasses in this module are also the authoritative configuration schema.
Field comments state the unit and the values accepted by :meth:`PlatformConfig.validate`.
See ``configs/config_reference.toml`` for a copy-and-edit configuration template.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
import tomllib

from .profiles import get_profile
from .interfaces import get_electrical_interface, select_electrical_interface
from .models.signal import pattern_bits, supported_patterns


@dataclass
class SimulationConfig:
    symbols: int = 16384  # PAM4 symbols per WDM lane; >= 512.
    tx_sps: int = 4  # Transmitter samples/symbol; integer >= 4.
    seed: int = 20260811  # Reproducible laser/receiver noise and Monte Carlo seed.
    pattern: str = "prbs13q"  # prbs13q, prbs31q, ssprq, or random.
    pattern_seed: int = 1  # PRBS register seed; bit i presets IEEE stage Si.
    pattern_lane_seed_stride: int = 0  # 0 repeats the same IEEE pattern on WDM lanes.
    discard_symbols: int = 256  # Symbols removed at both ends after alignment.


@dataclass
class MeasuredS21Config:
    """Measured small-signal response applied to an electrical waveform.

    ``path`` may point to a Touchstone ``.s2p`` file or a CSV file.  Relative
    paths are resolved relative to the TOML file.  CSV files use the documented
    frequency/magnitude/phase columns; Touchstone files use their option line.
    """

    enabled: bool = False
    path: str = ""
    file_format: str = "auto"  # auto, touchstone, or csv.
    frequency_unit: str = "auto"  # CSV: auto, hz, khz, mhz, or ghz.
    magnitude_format: str = "db"  # CSV: db or linear.
    phase_unit: str = "deg"  # CSV: deg or rad.
    extrapolation: str = "hold"  # hold or zero outside the measured band.
    normalize_dc: bool = False  # True removes measured insertion loss at DC.
    remove_delay: bool = False  # True removes best-fit bulk group delay.
    replace_ideal_bandwidth: bool = True  # False cascades measured and ideal filters.


@dataclass
class LaserConfig:
    wavelength_nm: float = 1311.0  # Selects the nearest wavelength in the profile.
    power_dbm: float = 3.0  # Average CW optical launch power per lane.
    rin_db_hz: float = -145.0  # One-sided white RIN density, dB/Hz.
    linewidth_hz: float = 0.0  # Lorentzian linewidth; 0 disables phase noise.


@dataclass
class TransmitterConfig:
    modulator: str = "mzm"  # mzm or eml.
    electrical_bandwidth_hz: float = 30e9  # Ideal TX -3 dB bandwidth.
    drive_vpp: float = 1.0  # MZM electrical drive swing, Vpp.
    vpi_v: float = 2.0  # MZM half-wave voltage, V.
    bias_phase_rad: float = 0.7853981633974483  # MZM quadrature is pi/4 in this model.
    chirp: float = 0.0  # Dimensionless MZM/EML chirp coefficient.
    extinction_ratio_db: float = 6.0  # EML extinction ratio; ignored by MZM.
    measured_s21: MeasuredS21Config = field(default_factory=MeasuredS21Config)
    laser: LaserConfig = field(default_factory=LaserConfig)


@dataclass
class FiberConfig:
    fiber_type: str = "G.652.D"  # Must be allowed by the selected profile.
    length_m: float = 2000.0  # Physical reach in metres.
    attenuation_db_km: float = 0.5  # Power attenuation, dB/km.
    dispersion_ps_nm_km: float = 0.0  # Chromatic dispersion at the lane wavelength.
    dispersion_slope_ps_nm2_km: float = 0.092  # Reserved for wavelength-dependent D.
    nonlinear_enabled: bool = False  # Enables scalar SPM or batched WDM SPM/XPM.
    gamma_w_inv_km: float = 1.3  # Kerr coefficient, 1/(W km).
    ssfm_steps: int = 8  # Split-step segments; increase after convergence testing.
    xpm_enabled: bool = True  # Cross-phase modulation for multi-lane WDM only.


@dataclass
class ReceiverConfig:
    processing_sps: float = 2.0  # DSP input rate: exactly 1, 1.125, or 2 SPS.
    adc_clock_offset_ppm: float = 0.0  # Sampling-frequency error tracked by MM.
    responsivity_a_w: float = 0.8  # Photodiode responsivity, A/W.
    bandwidth_hz: float = 30e9  # Ideal RX -3 dB/noise bandwidth.
    tia_gain_ohm: float = 1000.0  # Transimpedance gain, V/A.
    thermal_noise_a_sqrt_hz: float = 8e-12  # Input current-noise density, A/sqrt(Hz).
    shot_noise_enabled: bool = True
    adc_bits: int = 8  # Ideal uniform ADC resolution.
    adc_full_scale_v: float = 1.0  # Differential peak-to-peak full scale.
    adc_phase_ui: float = 0.5  # Initial sampling phase in unit intervals.
    measured_s21: MeasuredS21Config = field(default_factory=MeasuredS21Config)


@dataclass
class TimingConfig:
    enabled: bool = True  # Mueller-Muller interpolating timing recovery.
    gain_mu: float = 0.01  # Proportional phase-loop gain.
    gain_omega: float = 0.0001  # Integral frequency-loop gain.
    max_clock_offset_ppm: float = 300.0  # Frequency-command clamp.


@dataclass
class DspConfig:
    timing: TimingConfig = field(default_factory=TimingConfig)
    ffe_taps: int = 11  # Positive odd number of symbol-spaced taps.
    training_symbols: int = 2048  # Known symbols used by trained equalizers.
    dfe_enabled: bool = False
    dfe_taps: int = 3
    dfe_step: float = 0.002
    mlse_enabled: bool = False
    mlse_channel_taps: tuple[float, ...] = (1.0,)  # 1..4 symbol-spaced channel taps.
    volterra_enabled: bool = False
    volterra_memory: int = 5
    volterra_order: int = 3


@dataclass
class OutputConfig:
    directory: str = "output"  # CLI --output overrides this directory.
    save_waveforms: bool = False  # Saves waveform arrays as compressed NPZ.


@dataclass
class PlatformConfig:
    profile: str = "ethernet_400gbase_fr4_100g_lane"  # Run `imdd-sim profiles`.
    architecture: str = "retimed"  # retimed, lpo, npo, lro, or pcie_phy.
    electrical_interface: str = "auto"  # auto or `imdd-sim interfaces` name.
    simulation: SimulationConfig = field(default_factory=SimulationConfig)
    transmitter: TransmitterConfig = field(default_factory=TransmitterConfig)
    fiber: FiberConfig = field(default_factory=FiberConfig)
    receiver: ReceiverConfig = field(default_factory=ReceiverConfig)
    dsp: DspConfig = field(default_factory=DspConfig)
    output: OutputConfig = field(default_factory=OutputConfig)
    standard_overrides: tuple[str, ...] = ()

    @property
    def symbol_rate_hz(self) -> float:
        return float(get_profile(self.profile).values["symbol_rate_gbd"]) * 1e9

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def validate(self) -> None:
        profile = get_profile(self.profile)
        if self.architecture not in {"retimed", "lpo", "npo", "lro", "pcie_phy"}:
            raise ValueError("architecture must be retimed, lpo, npo, lro, or pcie_phy")
        if self.electrical_interface == "auto":
            interface = select_electrical_interface(
                self.architecture,
                float(profile.values["line_rate_gbps"]),
                profile.family,
            )
        else:
            interface = get_electrical_interface(self.electrical_interface)
            if interface.generation_gbps != float(profile.values["line_rate_gbps"]):
                raise ValueError("electrical interface and optical lane generation do not match")
        if self.simulation.tx_sps < 4:
            raise ValueError("simulation.tx_sps must be at least 4")
        if self.simulation.symbols < 512:
            raise ValueError("simulation.symbols must be at least 512")
        configurable_patterns = set(supported_patterns()) - {"custom"}
        if self.simulation.pattern.strip().lower() not in configurable_patterns:
            raise ValueError(
                "simulation.pattern must be one of "
                f"{sorted(configurable_patterns)}; custom requires the Python API"
            )
        if self.simulation.pattern_seed < 0:
            raise ValueError("simulation.pattern_seed must be non-negative")
        if self.simulation.pattern_lane_seed_stride < 0:
            raise ValueError("simulation.pattern_lane_seed_stride must be non-negative")
        # Exercise the first and last WDM lane here so an invalid PRBS register
        # seed fails during configuration loading rather than deep in a run.
        lane_count = len(profile.values["wavelengths_nm"])
        for lane in {0, lane_count - 1}:
            lane_seed = (
                self.simulation.pattern_seed
                + lane * self.simulation.pattern_lane_seed_stride
            )
            pattern_bits(self.simulation.pattern, 1, lane_seed)
        if self.simulation.discard_symbols * 2 >= self.simulation.symbols:
            raise ValueError("discard_symbols is too large for the simulation length")
        if self.receiver.processing_sps not in {1.0, 1.125, 2.0}:
            raise ValueError("receiver.processing_sps must be 1, 1.125, or 2")
        if abs(self.receiver.adc_clock_offset_ppm) > self.dsp.timing.max_clock_offset_ppm:
            raise ValueError("ADC clock offset exceeds the configured MM tracking range")
        if self.transmitter.modulator not in {"mzm", "eml"}:
            raise ValueError("transmitter.modulator must be 'mzm' or 'eml'")
        for location, response in (
            ("transmitter.measured_s21", self.transmitter.measured_s21),
            ("receiver.measured_s21", self.receiver.measured_s21),
        ):
            if response.file_format not in {"auto", "touchstone", "csv"}:
                raise ValueError(f"{location}.file_format must be auto, touchstone, or csv")
            if response.frequency_unit not in {"auto", "hz", "khz", "mhz", "ghz"}:
                raise ValueError(f"{location}.frequency_unit is invalid")
            if response.magnitude_format not in {"db", "linear"}:
                raise ValueError(f"{location}.magnitude_format must be db or linear")
            if response.phase_unit not in {"deg", "rad"}:
                raise ValueError(f"{location}.phase_unit must be deg or rad")
            if response.extrapolation not in {"hold", "zero"}:
                raise ValueError(f"{location}.extrapolation must be hold or zero")
            if response.enabled and not response.path:
                raise ValueError(f"{location}.path is required when enabled")
            if response.enabled and not Path(response.path).is_file():
                raise ValueError(f"{location}.path does not exist: {response.path}")
        if self.fiber.fiber_type not in set(profile.values["fiber_types"]):
            raise ValueError(
                f"fiber type {self.fiber.fiber_type!r} is not allowed by {profile.name}"
            )
        if self.fiber.length_m <= 0:
            raise ValueError("fiber.length_m must be positive")
        if self.fiber.length_m > float(profile.values["reach_m"]):
            self.standard_overrides = tuple(
                sorted(set(self.standard_overrides) | {"fiber.length_m"})
            )
        if self.transmitter.laser.wavelength_nm <= 0:
            raise ValueError("laser wavelength must be positive")
        if self.dsp.ffe_taps < 1 or self.dsp.ffe_taps % 2 == 0:
            raise ValueError("dsp.ffe_taps must be a positive odd integer")
        if self.dsp.mlse_enabled and len(self.dsp.mlse_channel_taps) > 4:
            raise ValueError("MLSE memory is limited to three symbols in the CPU MVP")
        if self.architecture in {"lpo", "npo", "lro"} and profile.family == "ethernet":
            # The optical and electrical generation is intentionally one-to-one in linear modes.
            if float(profile.values["line_rate_gbps"]) not in {100.0, 200.0}:
                raise ValueError("linear architectures require a 100G or 200G lane profile")
            if interface.architecture != self.architecture:
                raise ValueError("linear architecture and electrical interface topology do not match")


def _build_laser(data: dict[str, Any]) -> LaserConfig:
    return LaserConfig(**data)


def _build_measured_s21(data: dict[str, Any], base_directory: Path) -> MeasuredS21Config:
    values = dict(data)
    if values.get("path"):
        path = Path(values["path"])
        if not path.is_absolute():
            path = (base_directory / path).resolve()
        values["path"] = str(path)
    return MeasuredS21Config(**values)


def _build_transmitter(data: dict[str, Any], base_directory: Path) -> TransmitterConfig:
    values = dict(data)
    values["laser"] = _build_laser(values.get("laser", {}))
    values["measured_s21"] = _build_measured_s21(
        values.get("measured_s21", {}), base_directory
    )
    return TransmitterConfig(**values)


def _build_receiver(data: dict[str, Any], base_directory: Path) -> ReceiverConfig:
    values = dict(data)
    values["measured_s21"] = _build_measured_s21(
        values.get("measured_s21", {}), base_directory
    )
    return ReceiverConfig(**values)


def _build_timing(data: dict[str, Any]) -> TimingConfig:
    return TimingConfig(**data)


def _build_dsp(data: dict[str, Any]) -> DspConfig:
    values = dict(data)
    values["timing"] = _build_timing(values.get("timing", {}))
    if "mlse_channel_taps" in values:
        values["mlse_channel_taps"] = tuple(values["mlse_channel_taps"])
    return DspConfig(**values)


def load_config(path: str | Path) -> PlatformConfig:
    config_path = Path(path)
    with config_path.open("rb") as stream:
        raw = tomllib.load(stream)
    known = {
        "profile",
        "architecture",
        "electrical_interface",
        "simulation",
        "transmitter",
        "fiber",
        "receiver",
        "dsp",
        "output",
    }
    unknown = set(raw) - known
    if unknown:
        raise ValueError(f"unknown top-level configuration keys: {sorted(unknown)}")
    config = PlatformConfig(
        profile=raw.get("profile", PlatformConfig.profile),
        architecture=raw.get("architecture", PlatformConfig.architecture),
        electrical_interface=raw.get("electrical_interface", PlatformConfig.electrical_interface),
        simulation=SimulationConfig(**raw.get("simulation", {})),
        transmitter=_build_transmitter(raw.get("transmitter", {}), config_path.parent),
        fiber=FiberConfig(**raw.get("fiber", {})),
        receiver=_build_receiver(raw.get("receiver", {}), config_path.parent),
        dsp=_build_dsp(raw.get("dsp", {})),
        output=OutputConfig(**raw.get("output", {})),
    )
    config.validate()
    return config
