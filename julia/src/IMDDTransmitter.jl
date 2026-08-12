"""Convert optical power from dBm to watts."""
function DbmToWatts(power_dbm::Real)::Float64
    return 1.0e-3 * 10.0^(Float64(power_dbm) / 10.0)
end

"""Repeat every PAM4 symbol by an integer number of samples."""
function OversampleSymbols(
    symbols::AbstractVector{<:Real},
    samples_per_symbol::Integer,
)::Vector{Float64}
    samples_per_symbol > 0 || throw(ArgumentError("samples_per_symbol must be positive"))
    isempty(symbols) && throw(ArgumentError("symbols must not be empty"))
    return repeat(Float64.(symbols); inner=Int(samples_per_symbol))
end

"""
    LowpassFft(signal, sample_rate_hz, bandwidth_hz; order=4)

Apply the same zero-phase Butterworth-like FFT-domain electrical low-pass used
by the Python platform. A non-positive bandwidth or a bandwidth at/above the
Nyquist frequency bypasses the filter and returns a copy.
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
    CwLaser(sample_count, sample_rate_hz, power_dbm, linewidth_hz, rng)

Generate a complex-envelope CW laser. A positive linewidth adds a Wiener phase
process; zero linewidth produces a constant real field.
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

"""Apply white relative-intensity noise over the represented Nyquist band."""
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

"""Apply the Python-platform Mach-Zehnder modulator behavioral model."""
function MzmModulate(
    laser_field::AbstractVector{<:Complex},
    drive::AbstractVector{<:Real},
    drive_vpp::Real,
    vpi_v::Real,
    bias_phase_rad::Real,
    chirp::Real=0.0,
)::Vector{ComplexF64}
    length(laser_field) == length(drive) ||
        throw(ArgumentError("laser_field and drive must have the same length"))
    isempty(drive) && throw(ArgumentError("drive must not be empty"))
    drive_vpp >= 0 || throw(ArgumentError("drive_vpp must not be negative"))
    vpi_v > 0 || throw(ArgumentError("vpi_v must be positive"))

    voltage = 0.5 .* Float64(drive_vpp) .* Float64.(drive)
    phase = Float64(bias_phase_rad) .+ pi .* voltage ./ (2.0 * Float64(vpi_v))
    modulated_field = ComplexF64.(laser_field) .* cos.(phase)
    if chirp == 0
        return modulated_field
    end

    intensity = max.(abs2.(modulated_field), floatmin(Float64))
    mean_intensity = max(sum(intensity) / length(intensity), floatmin(Float64))
    chirp_phase = 0.5 .* Float64(chirp) .* log.(intensity ./ mean_intensity)
    return modulated_field .* cis.(chirp_phase)
end

"""Apply the Python-platform electro-absorption modulator behavioral model."""
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
    RunImddTransmitter(pattern, symbol_count; kwargs...)

Run one procedural IMDD PAM4 transmitter lane and return every processing stage
for inspection. The processing order mirrors the Python platform: pattern,
Gray mapping, oversampling, electrical low-pass, CW laser/RIN, then MZM or EML.
"""
function RunImddTransmitter(
    pattern::AbstractString,
    symbol_count::Integer;
    pattern_seed::Integer=1,
    custom_bits::Union{Nothing, AbstractVector{<:Integer}}=nothing,
    noise_seed::Integer=20260811,
    symbol_rate_hz::Real=53.125e9,
    samples_per_symbol::Integer=4,
    electrical_bandwidth_hz::Real=30.0e9,
    filter_order::Integer=4,
    wavelength_nm::Real=1311.0,
    laser_power_dbm::Real=3.0,
    laser_linewidth_hz::Real=0.0,
    rin_db_hz::Real=-145.0,
    modulator::AbstractString="mzm",
    drive_vpp::Real=1.0,
    vpi_v::Real=2.0,
    bias_phase_rad::Real=pi / 4,
    chirp::Real=0.0,
    extinction_ratio_db::Real=6.0,
)
    symbol_count > 0 || throw(ArgumentError("symbol_count must be positive"))
    noise_seed >= 0 || throw(ArgumentError("noise_seed must not be negative"))
    symbol_rate_hz > 0 || throw(ArgumentError("symbol_rate_hz must be positive"))
    samples_per_symbol > 0 || throw(ArgumentError("samples_per_symbol must be positive"))
    wavelength_nm > 0 || throw(ArgumentError("wavelength_nm must be positive"))

    bits = PatternBits(
        pattern,
        symbol_count;
        seed=pattern_seed,
        custom_bits=custom_bits,
    )
    symbol_codes = GrayMapPam4Codes(bits)
    symbols = GrayMapPam4(bits)
    electrical_drive_raw = OversampleSymbols(symbols, samples_per_symbol)
    sample_rate_hz = Float64(symbol_rate_hz) * Int(samples_per_symbol)
    electrical_drive = LowpassFft(
        electrical_drive_raw,
        sample_rate_hz,
        electrical_bandwidth_hz;
        order=filter_order,
    )

    rng = MersenneTwister(noise_seed)
    laser_field_ideal = CwLaser(
        length(electrical_drive),
        sample_rate_hz,
        laser_power_dbm,
        laser_linewidth_hz,
        rng,
    )
    laser_field = AddRin(laser_field_ideal, sample_rate_hz, rin_db_hz, rng)

    modulator_name = lowercase(strip(modulator))
    if modulator_name == "mzm"
        optical_field = MzmModulate(
            laser_field,
            electrical_drive,
            drive_vpp,
            vpi_v,
            bias_phase_rad,
            chirp,
        )
    elseif modulator_name == "eml"
        optical_field = EmlModulate(
            laser_field,
            electrical_drive,
            extinction_ratio_db,
            chirp,
        )
    else
        throw(ArgumentError("modulator must be 'mzm' or 'eml'"))
    end

    return (
        bits=bits,
        symbol_codes=symbol_codes,
        symbols=symbols,
        electrical_drive_raw=electrical_drive_raw,
        electrical_drive=electrical_drive,
        laser_field_ideal=laser_field_ideal,
        laser_field=laser_field,
        optical_field=optical_field,
        optical_power_w=abs2.(optical_field),
        sample_rate_hz=sample_rate_hz,
        symbol_rate_hz=Float64(symbol_rate_hz),
        samples_per_symbol=Int(samples_per_symbol),
        wavelength_nm=Float64(wavelength_nm),
        modulator=modulator_name,
    )
end
