#!/usr/bin/env julia

include(joinpath(@__DIR__, "..", "src", "IMDD.jl"))

"""Print transmitter CLI options and their defaults to `io`."""
function Usage(io::IO=stdout)
    println(io, "Usage: julia --project=julia julia/bin/run_transmitter.jl [options]")
    println(io, "  --noise-seed N      Master seed for all noise sources (default: 20260811)")
    println(io, "  --pattern NAME      Pattern name (default: prbs13q)")
    println(io, "  --symbols N         Number of PAM4 symbols (default: 1024)")
    println(io, "  --pattern-seed N    Pattern seed (default: 1)")
    println(io, "  --symbol-rate HZ    Symbol rate in baud (default: 53.125e9)")
    println(io, "  --sps N             Transmitter samples per symbol (default: 4)")
    println(io, "  --dac-bits N        DAC resolution in bits (default: 8)")
    println(io, "  --dac-full-scale X  DAC normalized positive full scale (default: 1.0)")
    println(io, "  --dac-jitter-ui X   DAC RMS jitter in UI (default: 0.0)")
    println(io, "  --dac-noise-rms X   DAC normalized RMS output noise (default: 0.0)")
    println(io, "  --bandwidth HZ      Electrical -3 dB bandwidth (default: 30e9)")
    println(io, "  --laser-power-dbm X CW laser power in dBm (default: 3.0)")
    println(io, "  --linewidth-hz X    Laser linewidth in Hz (default: 0.0)")
    println(io, "  --rin-db-hz X       RIN density in dB/Hz (default: -145.0)")
    println(io, "  --modulator NAME    Optical modulator: mzm or eml (default: mzm)")
    println(io, "  --extinction-ratio-db X  Modulator extinction ratio (default: 6.0)")
    println(io, "  --tx-fir-taps LIST  Comma-separated sample-spaced FIR taps")
    println(io, "  --nonlinear-coefficients LIST  Polynomial c1,c2,...; enables compensation")
    println(io, "  --gain-mode MODE    DAC input gain: adaptive or fixed (default: adaptive)")
    println(io, "  --fixed-gain X      Gain used in fixed mode (default: 1.0)")
    println(io, "  --gain-search-span DB  Adaptive total search span (default: 24.0)")
    println(io, "  --gain-search-points N Adaptive gain grid size (default: 129)")
    println(io, "  --gain-max-samples N   Adaptive cost sample limit (default: 65536)")
    println(io, "  --output PATH       Write final optical field samples to CSV")
end

"""Return the value following `option`, or throw when the value is missing."""
function OptionValue(args::Vector{String}, index::Int, option::String)
    index < length(args) || throw(ArgumentError("$option requires a value"))
    return args[index + 1]
end

"""
    ParseArgs(args)

Parse command-line text directly into one `ImddTransmitterParameters` object.
DSP options update `parameters.dsp`; DAC and modulator options update
`parameters.device`; `--noise-seed` updates the top-level master seed. The
output CSV path is returned separately because it is an application output
setting rather than a transmitter model parameter.
"""
function ParseArgs(args::Vector{String})
    parameters = ImddTransmitterParameters()
    output_path = nothing

    index = 1
    while index <= length(args)
        argument = args[index]
        if argument in ("-h", "--help")
            Usage()
            exit(0)
        elseif argument == "--pattern"
            parameters.dsp.pattern = OptionValue(args, index, argument)
        elseif argument == "--symbols"
            parameters.dsp.symbol_count = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--pattern-seed"
            parameters.dsp.pattern_seed = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--noise-seed"
            parameters.noise_seed = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--symbol-rate"
            parameters.dsp.symbol_rate_hz = parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--sps"
            parameters.dsp.samples_per_symbol = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--dac-bits"
            parameters.device.dac_resolution_bits = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--dac-full-scale"
            parameters.device.dac_full_scale = parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--dac-jitter-ui"
            parameters.device.dac_jitter_rms_ui = parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--dac-noise-rms"
            parameters.device.dac_noise_rms = parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--bandwidth"
            parameters.device.electrical_bandwidth_hz =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--laser-power-dbm"
            parameters.device.laser_power_dbm =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--linewidth-hz"
            parameters.device.laser_linewidth_hz =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--rin-db-hz"
            parameters.device.rin_db_hz =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--modulator"
            parameters.device.modulator = OptionValue(args, index, argument)
        elseif argument == "--extinction-ratio-db"
            parameters.device.extinction_ratio_db =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--tx-fir-taps"
            tap_text = split(OptionValue(args, index, argument), ',')
            parameters.dsp.tx_fir_taps = parse.(Float64, strip.(tap_text))
        elseif argument == "--nonlinear-coefficients"
            coefficient_text = split(OptionValue(args, index, argument), ',')
            parameters.dsp.tx_nonlinear_coefficients =
                parse.(Float64, strip.(coefficient_text))
            parameters.dsp.tx_nonlinear_compensation_enabled = true
        elseif argument == "--gain-mode"
            parameters.dsp.tx_gain_mode = OptionValue(args, index, argument)
        elseif argument == "--fixed-gain"
            parameters.dsp.tx_fixed_gain =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--gain-search-span"
            parameters.dsp.tx_gain_search_span_db =
                parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--gain-search-points"
            parameters.dsp.tx_gain_search_points =
                parse(Int, OptionValue(args, index, argument))
        elseif argument == "--gain-max-samples"
            parameters.dsp.tx_gain_max_samples =
                parse(Int, OptionValue(args, index, argument))
        elseif argument == "--output"
            output_path = OptionValue(args, index, argument)
        else
            throw(ArgumentError("unknown option: $argument"))
        end
        index += 2
    end
    return parameters, output_path
end

"""
    WriteCsv(path, result)

Write the final complex optical field from `RunImddTransmitter`.
`symbol_index` identifies the source symbol interval associated with each
oversampled optical sample. Optical power is `abs2(optical_field)` in watts.
"""
function WriteCsv(
    path::AbstractString,
    optical_field::AbstractVector{<:Complex},
    samples_per_symbol::Integer,
)
    open(path, "w") do io
        println(io, "sample_index,symbol_index,field_real,field_imag,optical_power_w")
        for sample_index in eachindex(optical_field)
            symbol_index = div(sample_index - 1, samples_per_symbol) + 1
            field_sample = optical_field[sample_index]
            println(
                io,
                sample_index, ',', symbol_index, ',',
                real(field_sample), ',', imag(field_sample), ',', abs2(field_sample),
            )
        end
    end
end

"""Run the CLI, print a compact configuration summary, and optionally export CSV."""
function RunCli(args::Vector{String})
    parameters, output_path = ParseArgs(args)
    optical_field = RunImddTransmitter(parameters)
    dsp = parameters.dsp
    device = parameters.device
    sample_rate_hz = dsp.symbol_rate_hz * dsp.samples_per_symbol

    println("noise_seed=$(parameters.noise_seed)")
    println("pattern=$(dsp.pattern) symbols=$(dsp.symbol_count)")
    println("samples=$(length(optical_field)) sample_rate_hz=$sample_rate_hz")
    println(
        "dac_bits=$(device.dac_resolution_bits) " *
        "dac_full_scale=$(device.dac_full_scale) " *
        "dac_jitter_rms_ui=$(device.dac_jitter_rms_ui) " *
        "dac_noise_rms=$(device.dac_noise_rms)",
    )
    println(
        "nonlinear_compensation=$(dsp.tx_nonlinear_compensation_enabled) " *
        "gain_mode=$(lowercase(strip(dsp.tx_gain_mode))) " *
        "fixed_gain=$(dsp.tx_fixed_gain)",
    )
    println(
        "laser_power_dbm=$(device.laser_power_dbm) " *
        "linewidth_hz=$(device.laser_linewidth_hz) " *
        "rin_db_hz=$(device.rin_db_hz) " *
        "modulator=$(lowercase(strip(device.modulator)))",
    )
    optical_power_w = abs2.(optical_field)
    mean_power_w = sum(optical_power_w) / length(optical_power_w)
    println(
        "optical_power_min_w=$(minimum(optical_power_w)) " *
        "optical_power_max_w=$(maximum(optical_power_w)) " *
        "optical_power_mean_w=$mean_power_w",
    )
    if output_path !== nothing
        WriteCsv(output_path, optical_field, dsp.samples_per_symbol)
        println("wrote $(length(optical_field)) samples to $output_path")
    end
end

try
    RunCli(ARGS)
catch error
    println(stderr, "error: ", sprint(showerror, error))
    Usage(stderr)
    exit(1)
end
