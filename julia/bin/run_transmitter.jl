#!/usr/bin/env julia

include(joinpath(@__DIR__, "..", "src", "IMDDPatterns.jl"))
using .IMDDPatterns

function Usage(io::IO=stdout)
    println(io, "Usage: julia --project=julia julia/bin/run_transmitter.jl [options]")
    println(io, "  --pattern NAME      Pattern name (default: prbs13q)")
    println(io, "  --symbols N         Number of PAM4 symbols (default: 1024)")
    println(io, "  --pattern-seed N    Pattern seed (default: 1)")
    println(io, "  --noise-seed N      Laser/RIN noise seed (default: 20260811)")
    println(io, "  --symbol-rate HZ    Symbol rate in baud (default: 53.125e9)")
    println(io, "  --sps N             Transmitter samples per symbol (default: 4)")
    println(io, "  --bandwidth HZ      Electrical -3 dB bandwidth (default: 30e9)")
    println(io, "  --modulator NAME    mzm or eml (default: mzm)")
    println(io, "  --output PATH       Write all sample-domain stages to CSV")
end

function OptionValue(args::Vector{String}, index::Int, option::String)
    index < length(args) || throw(ArgumentError("$option requires a value"))
    return args[index + 1]
end

function ParseArgs(args::Vector{String})
    options = Dict{Symbol, Any}(
        :pattern => "prbs13q",
        :symbols => 1024,
        :pattern_seed => 1,
        :noise_seed => 20260811,
        :symbol_rate_hz => 53.125e9,
        :samples_per_symbol => 4,
        :electrical_bandwidth_hz => 30.0e9,
        :modulator => "mzm",
        :output => nothing,
    )

    index = 1
    while index <= length(args)
        argument = args[index]
        if argument in ("-h", "--help")
            Usage()
            exit(0)
        elseif argument == "--pattern"
            options[:pattern] = OptionValue(args, index, argument)
        elseif argument == "--symbols"
            options[:symbols] = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--pattern-seed"
            options[:pattern_seed] = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--noise-seed"
            options[:noise_seed] = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--symbol-rate"
            options[:symbol_rate_hz] = parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--sps"
            options[:samples_per_symbol] = parse(Int, OptionValue(args, index, argument))
        elseif argument == "--bandwidth"
            options[:electrical_bandwidth_hz] = parse(Float64, OptionValue(args, index, argument))
        elseif argument == "--modulator"
            options[:modulator] = OptionValue(args, index, argument)
        elseif argument == "--output"
            options[:output] = OptionValue(args, index, argument)
        else
            throw(ArgumentError("unknown option: $argument"))
        end
        index += 2
    end
    return options
end

function WriteCsv(path::AbstractString, result)
    open(path, "w") do io
        println(
            io,
            "sample_index,symbol_index,drive_raw,drive_filtered,laser_real,laser_imag,field_real,field_imag,optical_power_w",
        )
        for sample_index in eachindex(result.optical_field)
            symbol_index = div(sample_index - 1, result.samples_per_symbol) + 1
            println(
                io,
                sample_index, ',', symbol_index, ',',
                result.electrical_drive_raw[sample_index], ',',
                result.electrical_drive[sample_index], ',',
                real(result.laser_field[sample_index]), ',',
                imag(result.laser_field[sample_index]), ',',
                real(result.optical_field[sample_index]), ',',
                imag(result.optical_field[sample_index]), ',',
                result.optical_power_w[sample_index],
            )
        end
    end
end

function RunCli(args::Vector{String})
    options = ParseArgs(args)
    result = RunImddTransmitter(
        options[:pattern],
        options[:symbols];
        pattern_seed=options[:pattern_seed],
        noise_seed=options[:noise_seed],
        symbol_rate_hz=options[:symbol_rate_hz],
        samples_per_symbol=options[:samples_per_symbol],
        electrical_bandwidth_hz=options[:electrical_bandwidth_hz],
        modulator=options[:modulator],
    )

    println("pattern=$(options[:pattern]) symbols=$(length(result.symbols))")
    println("modulator=$(result.modulator) sample_rate_hz=$(result.sample_rate_hz)")
    println("mean_launch_power_w=$(sum(result.optical_power_w) / length(result.optical_power_w))")
    if options[:output] !== nothing
        WriteCsv(options[:output], result)
        println("wrote $(length(result.optical_field)) samples to $(options[:output])")
    end
end

try
    RunCli(ARGS)
catch error
    println(stderr, "error: ", sprint(showerror, error))
    Usage(stderr)
    exit(1)
end
