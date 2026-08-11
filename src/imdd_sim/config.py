"""Typed TOML configuration and validation."""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any
import tomllib

from .profiles import get_profile
from .interfaces import get_electrical_interface, select_electrical_interface


@dataclass
class SimulationConfig:
    symbols: int = 16384
    tx_sps: int = 4
    seed: int = 20260811
    pattern: str = "prbs13q"
    discard_symbols: int = 256


@dataclass
class LaserConfig:
    wavelength_nm: float = 1311.0
    power_dbm: float = 3.0
    rin_db_hz: float = -145.0
    linewidth_hz: float = 0.0


@dataclass
class TransmitterConfig:
    modulator: str = "mzm"
    electrical_bandwidth_hz: float = 30e9
    drive_vpp: float = 1.0
    vpi_v: float = 2.0
    bias_phase_rad: float = 0.7853981633974483
    chirp: float = 0.0
    extinction_ratio_db: float = 6.0
    laser: LaserConfig = field(default_factory=LaserConfig)


@dataclass
class FiberConfig:
    fiber_type: str = "G.652.D"
    length_m: float = 2000.0
    attenuation_db_km: float = 0.5
    dispersion_ps_nm_km: float = 0.0
    dispersion_slope_ps_nm2_km: float = 0.092
    nonlinear_enabled: bool = False
    gamma_w_inv_km: float = 1.3
    ssfm_steps: int = 8
    xpm_enabled: bool = True


@dataclass
class ReceiverConfig:
    processing_sps: float = 2.0
    adc_clock_offset_ppm: float = 0.0
    responsivity_a_w: float = 0.8
    bandwidth_hz: float = 30e9
    tia_gain_ohm: float = 1000.0
    thermal_noise_a_sqrt_hz: float = 8e-12
    shot_noise_enabled: bool = True
    adc_bits: int = 8
    adc_full_scale_v: float = 1.0
    adc_phase_ui: float = 0.5


@dataclass
class TimingConfig:
    enabled: bool = True
    gain_mu: float = 0.01
    gain_omega: float = 0.0001
    max_clock_offset_ppm: float = 300.0


@dataclass
class DspConfig:
    timing: TimingConfig = field(default_factory=TimingConfig)
    ffe_taps: int = 11
    training_symbols: int = 2048
    dfe_enabled: bool = False
    dfe_taps: int = 3
    dfe_step: float = 0.002
    mlse_enabled: bool = False
    mlse_channel_taps: tuple[float, ...] = (1.0,)
    volterra_enabled: bool = False
    volterra_memory: int = 5
    volterra_order: int = 3


@dataclass
class OutputConfig:
    directory: str = "output"
    save_waveforms: bool = False


@dataclass
class PlatformConfig:
    profile: str = "ethernet_400gbase_fr4_100g_lane"
    architecture: str = "retimed"
    electrical_interface: str = "auto"
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
        if self.simulation.discard_symbols * 2 >= self.simulation.symbols:
            raise ValueError("discard_symbols is too large for the simulation length")
        if self.receiver.processing_sps not in {1.0, 1.125, 2.0}:
            raise ValueError("receiver.processing_sps must be 1, 1.125, or 2")
        if abs(self.receiver.adc_clock_offset_ppm) > self.dsp.timing.max_clock_offset_ppm:
            raise ValueError("ADC clock offset exceeds the configured MM tracking range")
        if self.transmitter.modulator not in {"mzm", "eml"}:
            raise ValueError("transmitter.modulator must be 'mzm' or 'eml'")
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


def _build_transmitter(data: dict[str, Any]) -> TransmitterConfig:
    values = dict(data)
    values["laser"] = _build_laser(values.get("laser", {}))
    return TransmitterConfig(**values)


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
        transmitter=_build_transmitter(raw.get("transmitter", {})),
        fiber=FiberConfig(**raw.get("fiber", {})),
        receiver=ReceiverConfig(**raw.get("receiver", {})),
        dsp=_build_dsp(raw.get("dsp", {})),
        output=OutputConfig(**raw.get("output", {})),
    )
    config.validate()
    return config
