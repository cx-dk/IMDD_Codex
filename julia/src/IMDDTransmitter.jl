"""
    DbmToWatts(power_dbm)

Convert optical power from dBm to watts using `1 mW * 10^(power_dbm/10)`.

# Arguments

- `power_dbm`: scalar optical power in dBm.

# Returns

A `Float64` power in watts. Negative dBm values are valid; non-finite inputs
propagate according to ordinary floating-point arithmetic.
"""
function DbmToWatts(power_dbm::Real)::Float64
    return 1.0e-3 * 10.0^(Float64(power_dbm) / 10.0)
end

const NOISE_STREAM_TAGS = Dict{Symbol, UInt64}(
    :dac => 0xdac0dac0dac0dac0,
    :laser => 0x1a5e1a5e1a5e1a5e,
    :rin => 0x71a071a071a071a0,
)

"""
    CreateNoiseRng(parameters, noise_source)
    CreateNoiseRng(noise_seed, noise_source)

Create a deterministic, component-specific random stream from one master seed.

`noise_source` must be `:dac`, `:laser`, or `:rin`. Each source is assigned a
fixed 64-bit stream tag, so the same `parameters.noise_seed` reproduces the
same waveform while the three devices remain statistically independent.
Creating or consuming one stream never changes another stream. This is safer
for modular simulations than sharing Julia's global RNG.

The returned `MersenneTwister` is newly initialized on every call. Reuse the
returned object within one device invocation when a continuous random sequence
is required.
"""
function CreateNoiseRng(
    noise_seed::Integer,
    noise_source::Symbol,
)::MersenneTwister
    noise_seed >= 0 || throw(ArgumentError("noise_seed must not be negative"))
    haskey(NOISE_STREAM_TAGS, noise_source) || throw(ArgumentError(
        "noise_source must be :dac, :laser, or :rin",
    ))
    seed_value = UInt64(mod(noise_seed, big(1) << 64))
    return MersenneTwister(xor(seed_value, NOISE_STREAM_TAGS[noise_source]))
end

function CreateNoiseRng(
    parameters::ImddTransmitterParameters,
    noise_source::Symbol,
)::MersenneTwister
    return CreateNoiseRng(parameters.noise_seed, noise_source)
end

"""
    OversampleSymbols(symbols, samples_per_symbol)

Create a rectangular zero-order-hold waveform by repeating every input symbol.

# Arguments

- `symbols`: non-empty real-valued symbol vector, normally normalized PAM4
  levels `[-1, -1/3, +1/3, +1]`.
- `samples_per_symbol`: positive integer transmitter oversampling ratio.

# Returns

A new `Vector{Float64}` of length
`length(symbols) * samples_per_symbol`. No pulse-shaping filter is applied in
this function; reconstruction filtering belongs to `GenerateDacWaveform`.
"""
function OversampleSymbols(
    symbols::AbstractVector{<:Real},
    samples_per_symbol::Integer,
)::Vector{Float64}
    samples_per_symbol > 0 || throw(ArgumentError("samples_per_symbol must be positive"))
    isempty(symbols) && throw(ArgumentError("symbols must not be empty"))
    return repeat(Float64.(symbols); inner=Int(samples_per_symbol))
end

"""
    UpsampleSymbols(symbols, samples_per_symbol)

Upsample a symbol sequence by inserting `samples_per_symbol - 1` zeros after
every symbol. Unlike `OversampleSymbols`, this function does not repeat symbol
values. It produces the impulse train expected by a sample-spaced TxFIR.

# Arguments

- `symbols`: non-empty real symbol vector, normally normalized PAM4 levels.
- `samples_per_symbol`: positive integer oversampling ratio.

# Returns

A `Vector{Float64}` of length `length(symbols) * samples_per_symbol`. Original
symbols occupy indices `1, 1+sps, 1+2sps, ...`; all other samples are zero.
"""
function UpsampleSymbols(
    symbols::AbstractVector{<:Real},
    samples_per_symbol::Integer,
)::Vector{Float64}
    isempty(symbols) && throw(ArgumentError("symbols must not be empty"))
    samples_per_symbol > 0 || throw(ArgumentError("samples_per_symbol must be positive"))

    upsampled_signal = zeros(Float64, length(symbols) * Int(samples_per_symbol))
    upsampled_signal[1:Int(samples_per_symbol):end] .= Float64.(symbols)
    return upsampled_signal
end

"""
    ApplyTxFir(signal, taps)

Apply a causal sample-spaced FIR filter while preserving input record length.

The first tap multiplies the current sample and subsequent taps multiply older
samples. Samples before the start of the record are treated as zero; the FIR
tail after the final input sample is intentionally truncated. Use guard symbols
when the complete transient response is required.

Both arguments must be non-empty and finite. The result is a new
`Vector{Float64}` with `length(signal)` samples.
"""
function ApplyTxFir(
    signal::AbstractVector{<:Real},
    taps::AbstractVector{<:Real},
)::Vector{Float64}
    isempty(signal) && throw(ArgumentError("signal must not be empty"))
    isempty(taps) && throw(ArgumentError("taps must not be empty"))
    all(isfinite, signal) || throw(ArgumentError("signal must contain only finite values"))
    all(isfinite, taps) || throw(ArgumentError("taps must contain only finite values"))

    values = Float64.(signal)
    coefficients = Float64.(taps)
    output = zeros(Float64, length(values))
    for sample_index in eachindex(values)
        last_tap = min(sample_index, length(coefficients))
        for tap_index in 1:last_tap
            output[sample_index] +=
                coefficients[tap_index] * values[sample_index - tap_index + 1]
        end
    end
    return output
end

"""
    ApplyTxNonlinearCompensation(signal, coefficients)

Apply a memoryless polynomial predistorter to a transmitter waveform.

The coefficient at index `k` multiplies `signal^k`, so the implemented model
is `y = c₁x + c₂x² + ... + cₙxⁿ`. There is intentionally no constant term:
the predistorter does not introduce a DC offset unless that behavior is
represented elsewhere in the transmitter. `[1.0]` is the identity model.

This function is suitable for a polynomial approximation to the inverse of a
measured DAC, driver, or modulator transfer characteristic. It is memoryless;
frequency-dependent compensation remains the responsibility of `ApplyTxFir`.
Both arguments must be non-empty and finite. A new `Vector{Float64}` with the
same length as `signal` is returned.
"""
function ApplyTxNonlinearCompensation(
    signal::AbstractVector{<:Real},
    coefficients::AbstractVector{<:Real},
)::Vector{Float64}
    isempty(signal) && throw(ArgumentError("signal must not be empty"))
    isempty(coefficients) && throw(ArgumentError("coefficients must not be empty"))
    all(isfinite, signal) || throw(ArgumentError("signal must contain only finite values"))
    all(isfinite, coefficients) ||
        throw(ArgumentError("coefficients must contain only finite values"))

    values = Float64.(signal)
    polynomial_coefficients = Float64.(coefficients)
    output = Vector{Float64}(undef, length(values))
    for sample_index in eachindex(values)
        input_value = values[sample_index]
        output_value = 0.0
        for coefficient in Iterators.reverse(polynomial_coefficients)
            output_value = (output_value + coefficient) * input_value
        end
        output[sample_index] = output_value
    end
    return output
end

"""
    RunTxDsp(parameters)

Run the independent transmitter DSP chain and return the DAC-input signal
before gain control.

Processing order is `PatternBits` → `GrayMapPam4` → zero-insertion upsampling →
`ApplyTxFir` → optional `ApplyTxNonlinearCompensation`.
`parameters.tx_fir_taps` is interpreted at the oversampled sample rate. When
it is empty, `ones(parameters.samples_per_symbol)` is used so the default
output is a rectangular PAM4 waveform compatible with the earlier
zero-order-hold implementation. Nonlinear compensation is enabled by
`parameters.tx_nonlinear_compensation_enabled` and uses the polynomial in
`parameters.tx_nonlinear_coefficients`.

The returned `Vector{Float64}` contains exactly
`symbol_count * samples_per_symbol` samples and is ready for fixed or adaptive
gain control before `GenerateDacWaveform`.
"""
function RunTxDsp(parameters::ImddDspParameters)::Vector{Float64}
    parameters.symbol_count > 0 ||
        throw(ArgumentError("symbol_count must be positive"))
    parameters.samples_per_symbol > 0 ||
        throw(ArgumentError("samples_per_symbol must be positive"))
    all(isfinite, parameters.tx_fir_taps) ||
        throw(ArgumentError("tx_fir_taps must contain only finite values"))

    bits = PatternBits(
        parameters.pattern,
        parameters.symbol_count;
        seed=parameters.pattern_seed,
        custom_bits=parameters.custom_bits,
    )
    symbols = GrayMapPam4(bits)
    upsampled_signal = UpsampleSymbols(symbols, parameters.samples_per_symbol)
    tx_fir_taps = isempty(parameters.tx_fir_taps) ?
        ones(Float64, parameters.samples_per_symbol) : parameters.tx_fir_taps
    tx_fir_output = ApplyTxFir(upsampled_signal, tx_fir_taps)
    if parameters.tx_nonlinear_compensation_enabled
        return ApplyTxNonlinearCompensation(
            tx_fir_output,
            parameters.tx_nonlinear_coefficients,
        )
    end
    return tx_fir_output
end

"""
    ApplyDacJitter(signal, samples_per_symbol, jitter_rms_ui, rng)

Apply independent Gaussian DAC sampling jitter using linear interpolation. The
jitter standard deviation is expressed in unit intervals. Zero jitter returns
an unchanged copy so deterministic ideal-DAC runs do not consume random values.

`samples_per_symbol` converts UI to sample units and `rng` controls
reproducibility. Source positions outside the represented waveform are clamped
to the first or last sample. The returned vector has the same length as
`signal`. This is a behavioral aperture-jitter model, not a transistor-level
clock or transition model.
"""
function ApplyDacJitter(
    signal::AbstractVector{<:Real},
    samples_per_symbol::Integer,
    jitter_rms_ui::Real,
    rng::AbstractRNG,
)::Vector{Float64}
    isempty(signal) && throw(ArgumentError("signal must not be empty"))
    samples_per_symbol > 0 || throw(ArgumentError("samples_per_symbol must be positive"))
    isfinite(jitter_rms_ui) || throw(ArgumentError("jitter_rms_ui must be finite"))
    jitter_rms_ui >= 0 || throw(ArgumentError("jitter_rms_ui must not be negative"))

    values = Float64.(signal)
    jitter_rms_ui == 0 && return copy(values)

    jittered_signal = Vector{Float64}(undef, length(values))
    jitter_rms_samples = Float64(jitter_rms_ui) * Int(samples_per_symbol)
    for index in eachindex(jittered_signal)
        source_position = clamp(
            index + jitter_rms_samples * randn(rng),
            firstindex(values),
            lastindex(values),
        )
        left_index = floor(Int, source_position)
        right_index = min(left_index + 1, lastindex(values))
        fraction = source_position - left_index
        jittered_signal[index] =
            (1.0 - fraction) * values[left_index] + fraction * values[right_index]
    end
    return jittered_signal
end

"""
    QuantizeDac(signal, resolution_bits; full_scale=1.0)

Clip and uniformly quantize a normalized DAC waveform. `full_scale` is the
positive peak magnitude; the output range is `[-full_scale, +full_scale]` and
contains `2^resolution_bits` evenly spaced output levels.

Values outside the range are clipped before code assignment. Both endpoints
are representable. Resolution is limited to 52 bits so every code step remains
meaningful in `Float64`. The returned vector has the same length as `signal`.
"""
function QuantizeDac(
    signal::AbstractVector{<:Real},
    resolution_bits::Integer;
    full_scale::Real=1.0,
)::Vector{Float64}
    isempty(signal) && throw(ArgumentError("signal must not be empty"))
    1 <= resolution_bits <= 52 ||
        throw(ArgumentError("resolution_bits must be in 1:52"))
    isfinite(full_scale) && full_scale > 0 ||
        throw(ArgumentError("full_scale must be finite and positive"))

    full_scale_value = Float64(full_scale)
    maximum_code = 2.0^Int(resolution_bits) - 1.0
    clipped_signal = clamp.(Float64.(signal), -full_scale_value, full_scale_value)
    normalized_codes = (clipped_signal .+ full_scale_value) .* maximum_code ./
        (2.0 * full_scale_value)
    quantized_codes = round.(normalized_codes)
    return (2.0 .* quantized_codes ./ maximum_code .- 1.0) .* full_scale_value
end

"""
    CalculateOptimalTxGain(signal, resolution_bits; kwargs...)

Calculate a quantization-aware positive gain for the signal entering the DAC.

The function searches gains around the peak-fitting value
`full_scale / maximum(abs, signal)` and minimizes input-referred mean-square
error after DAC clipping and quantization. For each candidate gain `g`, the
cost is `mean((QuantizeDac(g .* signal) ./ g - signal).^2)`. This objective
therefore trades lower quantization error against overload clipping instead of
assuming that the largest sample must always fit exactly within full scale.

# Keyword parameters

- `full_scale`: positive DAC peak full scale.
- `search_span_db`: total logarithmic gain-search span centered on peak fit.
- `search_points`: number of uniformly spaced gain candidates in dB.
- `max_samples`: maximum deterministic, uniformly decimated samples used in
  the cost calculation. This bounds search time for long patterns.

The returned value is a finite positive `Float64`. An all-zero waveform returns
`1.0` because its quantization cost is independent of gain. The search is a
bounded grid approximation, so callers that need a finer optimum can increase
`search_points` or reduce `search_span_db` around a known operating region.
"""
function CalculateOptimalTxGain(
    signal::AbstractVector{<:Real},
    resolution_bits::Integer;
    full_scale::Real=1.0,
    search_span_db::Real=24.0,
    search_points::Integer=129,
    max_samples::Integer=65_536,
)::Float64
    isempty(signal) && throw(ArgumentError("signal must not be empty"))
    all(isfinite, signal) || throw(ArgumentError("signal must contain only finite values"))
    1 <= resolution_bits <= 52 ||
        throw(ArgumentError("resolution_bits must be in 1:52"))
    isfinite(full_scale) && full_scale > 0 ||
        throw(ArgumentError("full_scale must be finite and positive"))
    isfinite(search_span_db) && search_span_db > 0 ||
        throw(ArgumentError("search_span_db must be finite and positive"))
    search_points >= 3 || throw(ArgumentError("search_points must be at least 3"))
    max_samples > 0 || throw(ArgumentError("max_samples must be positive"))

    values = Float64.(signal)
    peak_value = maximum(abs, values)
    peak_value == 0 && return 1.0

    sample_stride = max(1, cld(length(values), Int(max_samples)))
    representative_samples = values[1:sample_stride:end]
    peak_fit_gain = min(Float64(full_scale) / peak_value, floatmax(Float64))

    function QuantizationCost(candidate_gain::Float64)::Float64
        quantized_signal = QuantizeDac(
            candidate_gain .* representative_samples,
            resolution_bits;
            full_scale=full_scale,
        )
        input_referred_error = quantized_signal ./ candidate_gain .- representative_samples
        return sum(abs2, input_referred_error) / length(input_referred_error)
    end

    best_gain = peak_fit_gain
    best_cost = QuantizationCost(best_gain)
    half_span_db = Float64(search_span_db) / 2.0
    for gain_offset_db in range(-half_span_db, half_span_db; length=Int(search_points))
        candidate_gain = peak_fit_gain * 10.0^(gain_offset_db / 20.0)
        isfinite(candidate_gain) || continue
        candidate_cost = QuantizationCost(candidate_gain)
        if candidate_cost < best_cost
            best_gain = candidate_gain
            best_cost = candidate_cost
        end
    end
    return best_gain
end

"""
    LowpassFft(signal, sample_rate_hz, bandwidth_hz; order=4)

Apply the same zero-phase Butterworth-like FFT-domain electrical low-pass used
by the Python platform. A non-positive bandwidth or a bandwidth at/above the
Nyquist frequency bypasses the filter and returns a copy.

# Arguments

- `signal`: non-empty real waveform.
- `sample_rate_hz`: positive sample rate in Hz.
- `bandwidth_hz`: nominal -3 dB bandwidth in Hz.
- `order`: positive response order, default `4`.

# Returns and model notes

Returns a `Vector{Float64}` with unchanged length. The magnitude response is
`1/sqrt(1 + (f/bandwidth_hz)^(2*order))`. FFT-domain multiplication produces a
zero-phase, circular-record filter; add guard samples when edge transients are
important.
"""
function LowpassFft(
    signal::AbstractVector{<:Real},
    sample_rate_hz::Real,
    bandwidth_hz::Real;
    order::Integer=4,
)::Vector{Float64}
    isempty(signal) && throw(ArgumentError("signal must not be empty"))
    sample_rate_hz > 0 || throw(ArgumentError("sample_rate_hz must be positive"))
    order > 0 || throw(ArgumentError("order must be positive"))

    values = Float64.(signal)
    if bandwidth_hz <= 0 || bandwidth_hz >= sample_rate_hz / 2
        return copy(values)
    end

    sample_count = length(values)
    frequency_step_hz = Float64(sample_rate_hz) / sample_count
    frequencies_hz = frequency_step_hz .* collect(0:div(sample_count, 2))
    response = 1.0 ./ sqrt.(1.0 .+ (frequencies_hz ./ Float64(bandwidth_hz)).^(2 * order))
    return irfft(rfft(values) .* response, sample_count)
end

"""
    GenerateDacWaveform(input_signal; kwargs...)

Convert an oversampled TxFIR output into a behavioral DAC output waveform.

The input is already sampled at the DAC rate; this function does not perform
symbol upsampling or pulse shaping. Processing order is aperture jitter,
full-scale clipping and quantization, additive DAC output noise, then electrical
reconstruction filtering.

# Keyword parameters

- `sample_rate_hz`: DAC sample rate in Hz.
- `samples_per_symbol`: used only to convert jitter from UI to sample units.
- `resolution_bits`, `full_scale`: configure uniform clipping/quantization.
- `jitter_rms_ui`: Gaussian aperture jitter standard deviation in UI.
- `noise_rms`: additive white DAC output noise in normalized amplitude.
- `bandwidth_hz`, `filter_order`: configure the reconstruction response.
- `rng`: random stream used by jitter and DAC output noise.

# Returns

A `Vector{Float64}` containing only the reconstructed DAC output. Noise is
added after quantization and before reconstruction filtering. Call
`ApplyDacJitter`, `QuantizeDac`, and `LowpassFft` separately when individual
DAC intermediate stages are required for debugging.
"""
function GenerateDacWaveform(
    input_signal::AbstractVector{<:Real};
    sample_rate_hz::Real=212.5e9,
    samples_per_symbol::Integer=4,
    resolution_bits::Integer=8,
    full_scale::Real=1.0,
    jitter_rms_ui::Real=0.0,
    noise_rms::Real=0.0,
    bandwidth_hz::Real=30.0e9,
    filter_order::Integer=4,
    rng::AbstractRNG=MersenneTwister(0),
)
    isempty(input_signal) && throw(ArgumentError("input_signal must not be empty"))
    sample_rate_hz > 0 || throw(ArgumentError("sample_rate_hz must be positive"))
    isfinite(noise_rms) || throw(ArgumentError("noise_rms must be finite"))
    noise_rms >= 0 || throw(ArgumentError("noise_rms must not be negative"))

    jittered_signal = ApplyDacJitter(
        input_signal,
        samples_per_symbol,
        jitter_rms_ui,
        rng,
    )
    quantized_signal = QuantizeDac(
        jittered_signal,
        resolution_bits;
        full_scale=full_scale,
    )
    noisy_signal = if noise_rms == 0
        copy(quantized_signal)
    else
        quantized_signal .+ Float64(noise_rms) .* randn(rng, length(quantized_signal))
    end
    output_signal = LowpassFft(
        noisy_signal,
        sample_rate_hz,
        bandwidth_hz;
        order=filter_order,
    )

    return output_signal
end

"""
    CwLaser(sample_count, sample_rate_hz, power_dbm, linewidth_hz, rng)

Generate a complex-envelope CW laser. A positive linewidth adds a Wiener phase
process; zero linewidth produces a constant real field.

`sample_count` is the output length, `sample_rate_hz` is in Hz, `power_dbm` is
the average optical power, and `linewidth_hz` is the Lorentzian linewidth. The
phase increment standard deviation is `sqrt(2*pi*linewidth/sample_rate)`.
The returned `Vector{ComplexF64}` has field units of `sqrt(watt)` and therefore
`abs2.(field)` is optical power in watts.
"""
function CwLaser(
    sample_count::Integer,
    sample_rate_hz::Real,
    power_dbm::Real,
    linewidth_hz::Real,
    rng::AbstractRNG,
)::Vector{ComplexF64}
    sample_count > 0 || throw(ArgumentError("sample_count must be positive"))
    sample_rate_hz > 0 || throw(ArgumentError("sample_rate_hz must be positive"))
    linewidth_hz >= 0 || throw(ArgumentError("linewidth_hz must not be negative"))

    amplitude = sqrt(DbmToWatts(power_dbm))
    if linewidth_hz == 0
        return fill(ComplexF64(amplitude), Int(sample_count))
    end

    phase_step_sigma = sqrt(2.0 * pi * Float64(linewidth_hz) / Float64(sample_rate_hz))
    field = Vector{ComplexF64}(undef, sample_count)
    phase = 0.0
    for index in eachindex(field)
        phase += phase_step_sigma * randn(rng)
        field[index] = amplitude * cis(phase)
    end
    return field
end

"""
    CwLaser(sample_count, sample_rate_hz, power_dbm, linewidth_hz, parameters)

Generate a CW laser using the `:laser` stream derived from the unified master
`parameters.noise_seed`. Repeating the call with unchanged parameters produces
the same optical field.
"""
function CwLaser(
    sample_count::Integer,
    sample_rate_hz::Real,
    power_dbm::Real,
    linewidth_hz::Real,
    parameters::ImddTransmitterParameters,
)::Vector{ComplexF64}
    return CwLaser(
        sample_count,
        sample_rate_hz,
        power_dbm,
        linewidth_hz,
        CreateNoiseRng(parameters, :laser),
    )
end

"""
    AddRin(field, sample_rate_hz, rin_db_hz, rng)

Apply white relative-intensity noise to a complex optical field.

`rin_db_hz` is the one-sided RIN density in dB/Hz. The model integrates it over
the represented Nyquist band (`sample_rate_hz/2`), perturbs instantaneous
optical power, clamps negative power to zero, and preserves the input phase.
The returned `Vector{ComplexF64}` has the same length as `field`. Passing
`-Inf` disables RIN exactly and is useful for deterministic tests.
"""
function AddRin(
    field::AbstractVector{<:Complex},
    sample_rate_hz::Real,
    rin_db_hz::Real,
    rng::AbstractRNG,
)::Vector{ComplexF64}
    isempty(field) && throw(ArgumentError("field must not be empty"))
    sample_rate_hz > 0 || throw(ArgumentError("sample_rate_hz must be positive"))
    isnan(rin_db_hz) && throw(ArgumentError("rin_db_hz must not be NaN"))

    rin_linear_hz = 10.0^(Float64(rin_db_hz) / 10.0)
    fractional_sigma = sqrt(max(rin_linear_hz * Float64(sample_rate_hz) / 2.0, 0.0))
    noisy_field = Vector{ComplexF64}(undef, length(field))
    for index in eachindex(field)
        fractional_power = max(1.0 + fractional_sigma * randn(rng), 0.0)
        noisy_field[index] = field[index] * sqrt(fractional_power)
    end
    return noisy_field
end

"""
    AddRin(field, sample_rate_hz, rin_db_hz, parameters)

Apply RIN using the `:rin` stream derived from the unified master
`parameters.noise_seed`. The RIN stream is independent of the DAC and laser
linewidth streams.
"""
function AddRin(
    field::AbstractVector{<:Complex},
    sample_rate_hz::Real,
    rin_db_hz::Real,
    parameters::ImddTransmitterParameters,
)::Vector{ComplexF64}
    return AddRin(
        field,
        sample_rate_hz,
        rin_db_hz,
        CreateNoiseRng(parameters, :rin),
    )
end

"""
    MzmModulate(
        laser_field,
        drive,
        drive_vpp,
        vpi_v,
        bias_phase_rad,
        extinction_ratio_db,
        chirp=0,
    )

Apply the Python-platform Mach-Zehnder modulator behavioral model.

`drive` is normalized electrical amplitude and is converted to voltage by
`voltage = drive_vpp * drive / 2`. Finite extinction ratio is represented as a
push-pull arm-amplitude imbalance with field transfer
`cos(phase) + im*sqrt(r_min)*sin(phase)`, where
`r_min = 10^(-extinction_ratio_db/10)`. Its maximum and minimum power
transmissions are exactly `1` and `r_min`. Passing `Inf` restores the ideal
`cos(phase)` model. Optional chirp adds an intensity-dependent phase without
changing instantaneous power. Input vectors must be non-empty and equal in
length. The result is a complex field in the same units as `laser_field`.
"""
function MzmModulate(
    laser_field::AbstractVector{<:Complex},
    drive::AbstractVector{<:Real},
    drive_vpp::Real,
    vpi_v::Real,
    bias_phase_rad::Real,
    extinction_ratio_db::Real,
    chirp::Real=0.0,
)::Vector{ComplexF64}
    length(laser_field) == length(drive) ||
        throw(ArgumentError("laser_field and drive must have the same length"))
    isempty(drive) && throw(ArgumentError("drive must not be empty"))
    drive_vpp >= 0 || throw(ArgumentError("drive_vpp must not be negative"))
    vpi_v > 0 || throw(ArgumentError("vpi_v must be positive"))
    isnan(extinction_ratio_db) &&
        throw(ArgumentError("extinction_ratio_db must not be NaN"))
    extinction_ratio_db >= 0 ||
        throw(ArgumentError("extinction_ratio_db must not be negative"))

    voltage = 0.5 .* Float64(drive_vpp) .* Float64.(drive)
    phase = Float64(bias_phase_rad) .+ pi .* voltage ./ (2.0 * Float64(vpi_v))
    minimum_power_ratio = 10.0^(-Float64(extinction_ratio_db) / 10.0)
    field_transfer = cos.(phase) .+ im .* sqrt(minimum_power_ratio) .* sin.(phase)
    modulated_field = ComplexF64.(laser_field) .* field_transfer
    if chirp == 0
        return modulated_field
    end

    intensity = max.(abs2.(modulated_field), floatmin(Float64))
    mean_intensity = max(sum(intensity) / length(intensity), floatmin(Float64))
    chirp_phase = 0.5 .* Float64(chirp) .* log.(intensity ./ mean_intensity)
    return modulated_field .* cis.(chirp_phase)
end

"""
    EmlModulate(laser_field, drive, extinction_ratio_db, chirp=0)

Apply the Python-platform electro-absorption modulator behavioral model.

The normalized `drive` is clipped to `[-1, +1]` and mapped linearly in optical
power between `10^(-extinction_ratio_db/10)` and unity transmission. Optional
chirp adds `chirp*log(transmission_power)/2` radians of optical phase. Input
vectors must be non-empty and equal in length. The returned complex field has
the same length and units as `laser_field`.
"""
function EmlModulate(
    laser_field::AbstractVector{<:Complex},
    drive::AbstractVector{<:Real},
    extinction_ratio_db::Real,
    chirp::Real=0.0,
)::Vector{ComplexF64}
    length(laser_field) == length(drive) ||
        throw(ArgumentError("laser_field and drive must have the same length"))
    isempty(drive) && throw(ArgumentError("drive must not be empty"))
    extinction_ratio_db >= 0 ||
        throw(ArgumentError("extinction_ratio_db must not be negative"))

    normalized_drive = clamp.((Float64.(drive) .+ 1.0) ./ 2.0, 0.0, 1.0)
    minimum_power_ratio = 10.0^(-Float64(extinction_ratio_db) / 10.0)
    transmission_power = minimum_power_ratio .+
        (1.0 - minimum_power_ratio) .* normalized_drive
    amplitude = sqrt.(transmission_power)
    phase = 0.5 .* Float64(chirp) .* log.(max.(transmission_power, floatmin(Float64)))
    return ComplexF64.(laser_field) .* amplitude .* cis.(phase)
end

"""
    RunImddTransmitter(parameters)

Run the digital/electrical front end of one IMDD PAM4 transmitter lane from a
unified `ImddTransmitterParameters` object.

Processing order:

1. validate the unified parameters;
2. call `RunTxDsp` for pattern generation, PAM4 mapping, upsampling, TxFIR,
   and optional memoryless nonlinear compensation;
3. apply either adaptive quantization-aware gain or the configured fixed gain;
4. pass the scaled signal into `GenerateDacWaveform`;
5. return only the reconstructed DAC output as `Vector{Float64}`.

Laser, RIN, MZM, and EML functions remain independent device models. They can
consume the returned DAC waveform in a later optical-transmitter stage without
making the electrical transmitter return structure unnecessarily large.
"""
function RunImddTransmitter(
    parameters::ImddTransmitterParameters,
)::Vector{Float64}
    ValidateTransmitterParameters(parameters)
    dsp = parameters.dsp
    device = parameters.device

    tx_dsp_output = RunTxDsp(dsp)
    tx_gain = if lowercase(strip(dsp.tx_gain_mode)) == "adaptive"
        CalculateOptimalTxGain(
            tx_dsp_output,
            device.dac_resolution_bits;
            full_scale=device.dac_full_scale,
            search_span_db=dsp.tx_gain_search_span_db,
            search_points=dsp.tx_gain_search_points,
            max_samples=dsp.tx_gain_max_samples,
        )
    else
        dsp.tx_fixed_gain
    end
    dac_input_signal = tx_gain .* tx_dsp_output
    sample_rate_hz = dsp.symbol_rate_hz * dsp.samples_per_symbol
    dac_rng = CreateNoiseRng(parameters, :dac)
    return GenerateDacWaveform(
        dac_input_signal;
        sample_rate_hz=sample_rate_hz,
        samples_per_symbol=dsp.samples_per_symbol,
        resolution_bits=device.dac_resolution_bits,
        full_scale=device.dac_full_scale,
        jitter_rms_ui=device.dac_jitter_rms_ui,
        noise_rms=device.dac_noise_rms,
        bandwidth_hz=device.electrical_bandwidth_hz,
        filter_order=device.filter_order,
        rng=dac_rng,
    )
end
