"""
    ImddDspParameters(; kwargs...)

Mutable sequence-generation and discrete-time processing parameters for one
IMDD transmitter lane. All keyword arguments are optional.

# Source and sample-grid options

- `pattern="prbs13q"`: any name returned by `SupportedPatterns()`, including
  IEEE patterns, engineering patterns, `"random"`, and `"custom"`.
- `symbol_count=1024`: positive number of PAM4 symbols to generate.
- `pattern_seed=1`: non-negative pattern seed. For PRBS, bit `i` presets
  register stage `Si`; valid nonzero ranges depend on the PRBS order. For
  `"random"`, it controls the reproducible random data sequence.
- `custom_bits=nothing`: optional `Vector{UInt8}` used only with
  `pattern="custom"`; values must be binary, non-empty, and repeat to the
  requested output length when fewer than two bits per symbol are supplied.
- `symbol_rate_hz=53.125e9`: positive symbol rate in baud.
- `samples_per_symbol=4`: positive integer oversampling ratio.

# TxFIR and nonlinear-compensation options

- `tx_fir_taps=Float64[]`: finite sample-spaced FIR coefficients. An empty
  vector selects `ones(samples_per_symbol)`, producing rectangular symbols.
- `tx_nonlinear_compensation_enabled=false`: set `true` to apply the memoryless
  polynomial predistorter after TxFIR.
- `tx_nonlinear_coefficients=[1.0]`: non-empty finite coefficients where index
  `k` multiplies `x^k`; `[1.0]` is the identity model.

# DAC-input gain options

- `tx_gain_mode="adaptive"`: `"adaptive"` minimizes input-referred DAC
  quantization/clipping error; `"fixed"` applies `tx_fixed_gain` directly.
- `tx_fixed_gain=1.0`: finite positive gain used only in fixed mode.
- `tx_gain_search_span_db=24.0`: finite positive total adaptive search span.
- `tx_gain_search_points=129`: adaptive grid size, at least `3`.
- `tx_gain_max_samples=65_536`: positive maximum number of waveform samples
  used by the adaptive cost evaluation.
"""
Base.@kwdef mutable struct ImddDspParameters
    pattern::String = "prbs13q"
    symbol_count::Int = 1024
    pattern_seed::Int = 1
    custom_bits::Union{Nothing, Vector{UInt8}} = nothing
    symbol_rate_hz::Float64 = 53.125e9
    samples_per_symbol::Int = 4
    tx_fir_taps::Vector{Float64} = Float64[]
    tx_nonlinear_compensation_enabled::Bool = false
    tx_nonlinear_coefficients::Vector{Float64} = [1.0]
    tx_gain_mode::String = "adaptive"
    tx_fixed_gain::Float64 = 1.0
    tx_gain_search_span_db::Float64 = 24.0
    tx_gain_search_points::Int = 129
    tx_gain_max_samples::Int = 65_536
end

"""
    ImddDeviceParameters(; kwargs...)

Mutable physical and behavioral device parameters for one IMDD transmitter
lane. All keyword arguments are optional.

# DAC/driver options

- `dac_resolution_bits=8`: integer resolution in `1:52`.
- `dac_full_scale=1.0`: finite positive normalized peak magnitude; DAC codes
  span `[-dac_full_scale, +dac_full_scale]`.
- `dac_jitter_rms_ui=0.0`: finite non-negative RMS aperture jitter in UI.
- `dac_noise_rms=0.0`: finite non-negative normalized RMS output noise.
- `electrical_bandwidth_hz=30.0e9`: finite non-negative reconstruction-filter
  bandwidth. `0` or a value at/above Nyquist bypasses filtering.
- `filter_order=4`: positive Butterworth-like response order.

# Laser options

- `wavelength_nm=1311.0`: finite positive wavelength in nm.
- `laser_power_dbm=3.0`: finite average launch power in dBm.
- `laser_linewidth_hz=0.0`: finite non-negative Lorentzian linewidth in Hz;
  `0` disables phase noise.
- `rin_db_hz=-145.0`: one-sided RIN density in dB/Hz; `-Inf` disables RIN.

# Modulator options

- `modulator="mzm"`: supported selections are `"mzm"` and `"eml"`.
- `drive_vpp=1.0`: finite non-negative peak-to-peak drive voltage in V.
- `vpi_v=2.0`: finite positive MZM half-wave voltage in V.
- `bias_phase_rad=pi/4`: finite MZM bias phase in radians.
- `chirp=0.0`: finite dimensionless chirp coefficient.
- `extinction_ratio_db=6.0`: non-negative extinction ratio in dB; `Inf`
  selects the ideal infinite-extinction MZM limit.
"""
Base.@kwdef mutable struct ImddDeviceParameters
    # DAC / driver
    dac_resolution_bits::Int = 8
    dac_full_scale::Float64 = 1.0
    dac_jitter_rms_ui::Float64 = 0.0
    dac_noise_rms::Float64 = 0.0
    electrical_bandwidth_hz::Float64 = 30.0e9
    filter_order::Int = 4

    # Laser
    wavelength_nm::Float64 = 1311.0
    laser_power_dbm::Float64 = 3.0
    laser_linewidth_hz::Float64 = 0.0
    rin_db_hz::Float64 = -145.0

    # Modulator
    modulator::String = "mzm"
    drive_vpp::Float64 = 1.0
    vpi_v::Float64 = 2.0
    bias_phase_rad::Float64 = pi / 4
    chirp::Float64 = 0.0
    extinction_ratio_db::Float64 = 6.0
end

"""
    ImddTransmitterParameters(; noise_seed=20260811, dsp=..., device=...)

Unified parameter object accepted by `RunImddTransmitter`.

`noise_seed` is the first field and the single master seed for every stochastic
device model. The `dsp` member contains sequence and discrete-time processing
settings, followed by the physical/behavioral `device` settings.
Component-specific streams are derived by `CreateNoiseRng`, so consuming DAC
random numbers does not shift the laser-linewidth or RIN sequence. The object
and both members are mutable, so callers can edit only the desired field:

# Optional keyword arguments

- `noise_seed=20260811`: non-negative master seed shared by all noise models.
- `dsp=ImddDspParameters()`: DSP configuration, listed before device
  configuration to match transmitter processing order.
- `device=ImddDeviceParameters()`: DAC, laser, and modulator configuration
  executed by `RunTxDevice` inside the whole transmitter.

```julia
parameters = ImddTransmitterParameters()
parameters.noise_seed = 7
parameters.dsp.symbol_count = 4096
parameters.device.dac_resolution_bits = 6
parameters.device.modulator = "eml"
result = RunImddTransmitter(parameters)
```
"""
Base.@kwdef mutable struct ImddTransmitterParameters
    noise_seed::Int = 20260811
    dsp::ImddDspParameters = ImddDspParameters()
    device::ImddDeviceParameters = ImddDeviceParameters()
end

"""
    ValidateTransmitterParameters(parameters)

Validate units, ranges, and supported device selections before allocating
waveforms. Returns the same object on success and throws `ArgumentError` with
the offending field name on failure.

Pattern-specific validation is completed by `PatternBits` during transmitter
execution because valid PRBS seed ranges depend on the selected pattern order.
"""
function ValidateTransmitterParameters(
    parameters::ImddTransmitterParameters,
)::ImddTransmitterParameters
    dsp = parameters.dsp
    device = parameters.device

    parameters.noise_seed >= 0 ||
        throw(ArgumentError("noise_seed must not be negative"))
    dsp.symbol_count > 0 || throw(ArgumentError("dsp.symbol_count must be positive"))
    dsp.pattern_seed >= 0 || throw(ArgumentError("dsp.pattern_seed must not be negative"))
    isfinite(dsp.symbol_rate_hz) && dsp.symbol_rate_hz > 0 ||
        throw(ArgumentError("dsp.symbol_rate_hz must be finite and positive"))
    dsp.samples_per_symbol > 0 ||
        throw(ArgumentError("dsp.samples_per_symbol must be positive"))
    all(isfinite, dsp.tx_fir_taps) ||
        throw(ArgumentError("dsp.tx_fir_taps must contain only finite values"))
    isempty(dsp.tx_nonlinear_coefficients) &&
        throw(ArgumentError("dsp.tx_nonlinear_coefficients must not be empty"))
    all(isfinite, dsp.tx_nonlinear_coefficients) ||
        throw(ArgumentError(
            "dsp.tx_nonlinear_coefficients must contain only finite values",
        ))
    gain_mode = lowercase(strip(dsp.tx_gain_mode))
    gain_mode in ("adaptive", "fixed") ||
        throw(ArgumentError("dsp.tx_gain_mode must be 'adaptive' or 'fixed'"))
    isfinite(dsp.tx_fixed_gain) && dsp.tx_fixed_gain > 0 ||
        throw(ArgumentError("dsp.tx_fixed_gain must be finite and positive"))
    isfinite(dsp.tx_gain_search_span_db) && dsp.tx_gain_search_span_db > 0 ||
        throw(ArgumentError("dsp.tx_gain_search_span_db must be finite and positive"))
    dsp.tx_gain_search_points >= 3 ||
        throw(ArgumentError("dsp.tx_gain_search_points must be at least 3"))
    dsp.tx_gain_max_samples > 0 ||
        throw(ArgumentError("dsp.tx_gain_max_samples must be positive"))

    1 <= device.dac_resolution_bits <= 52 ||
        throw(ArgumentError("device.dac_resolution_bits must be in 1:52"))
    isfinite(device.dac_full_scale) && device.dac_full_scale > 0 ||
        throw(ArgumentError("device.dac_full_scale must be finite and positive"))
    isfinite(device.dac_jitter_rms_ui) && device.dac_jitter_rms_ui >= 0 ||
        throw(ArgumentError("device.dac_jitter_rms_ui must be finite and non-negative"))
    isfinite(device.dac_noise_rms) && device.dac_noise_rms >= 0 ||
        throw(ArgumentError("device.dac_noise_rms must be finite and non-negative"))
    isfinite(device.electrical_bandwidth_hz) && device.electrical_bandwidth_hz >= 0 ||
        throw(ArgumentError(
            "device.electrical_bandwidth_hz must be finite and non-negative",
        ))
    device.filter_order > 0 ||
        throw(ArgumentError("device.filter_order must be positive"))

    isfinite(device.wavelength_nm) && device.wavelength_nm > 0 ||
        throw(ArgumentError("device.wavelength_nm must be finite and positive"))
    isfinite(device.laser_power_dbm) ||
        throw(ArgumentError("device.laser_power_dbm must be finite"))
    isfinite(device.laser_linewidth_hz) && device.laser_linewidth_hz >= 0 ||
        throw(ArgumentError("device.laser_linewidth_hz must be finite and non-negative"))
    isnan(device.rin_db_hz) && throw(ArgumentError("device.rin_db_hz must not be NaN"))

    modulator_name = lowercase(strip(device.modulator))
    modulator_name in ("mzm", "eml") ||
        throw(ArgumentError("device.modulator must be 'mzm' or 'eml'"))
    isfinite(device.drive_vpp) && device.drive_vpp >= 0 ||
        throw(ArgumentError("device.drive_vpp must be finite and non-negative"))
    isfinite(device.vpi_v) && device.vpi_v > 0 ||
        throw(ArgumentError("device.vpi_v must be finite and positive"))
    isfinite(device.bias_phase_rad) ||
        throw(ArgumentError("device.bias_phase_rad must be finite"))
    isfinite(device.chirp) || throw(ArgumentError("device.chirp must be finite"))
    !isnan(device.extinction_ratio_db) && device.extinction_ratio_db >= 0 ||
        throw(ArgumentError("device.extinction_ratio_db must be non-negative or Inf"))

    return parameters
end
