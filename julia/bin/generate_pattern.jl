#!/usr/bin/env julia

include(joinpath(@__DIR__, "..", "src", "IMDDPatterns.jl"))
using .IMDDPatterns

function usage(io::IO=stdout)
    println(io, "Usage: julia --project=julia julia/bin/generate_pattern.jl [options]")
    println(io, "  --pattern NAME    Pattern name (default: prbs13q)")
    println(io, "  --symbols N       Number of PAM4 symbols (default: 1024)")
    println(io, "  --seed N          Integer seed (default: 1)")
    println(io, "  --custom BITS     Repeated custom bits, for example 001101")
    println(io, "  --output PATH     Write CSV columns index,bit0,bit1,symbol")
    println(io, "  --list            List supported pattern names")
end

function option_value(args::Vector{String}, index::Int, option::String)
    index < length(args) || throw(ArgumentError("$option requires a value"))
    return args[index + 1]
end

function parse_args(args::Vector{String})
    options = Dict{Symbol, Any}(
        :pattern => "prbs13q", :symbols => 1024, :seed => 1,
        :custom_bits => nothing, :output => nothing,
    )
    index = 1
    while index <= length(args)
        argument = args[index]
        if argument in ("-h", "--help")
            usage()
            exit(0)
        elseif argument == "--list"
            println.(supported_patterns())
            exit(0)
        elseif argument == "--pattern"
            options[:pattern] = option_value(args, index, argument)
            index += 2
        elseif argument == "--symbols"
            options[:symbols] = parse(Int, option_value(args, index, argument))
            index += 2
        elseif argument == "--seed"
            options[:seed] = parse(Int, option_value(args, index, argument))
            index += 2
        elseif argument == "--custom"
            value = option_value(args, index, argument)
            all(character -> character in ('0', '1'), value) ||
                throw(ArgumentError("--custom may contain only 0 and 1"))
            options[:custom_bits] = [character == '1' ? 1 : 0 for character in value]
            options[:pattern] = "custom"
            index += 2
        elseif argument == "--output"
            options[:output] = option_value(args, index, argument)
            index += 2
        else
            throw(ArgumentError("unknown option: $argument"))
        end
    end
    return options
end

function main(args::Vector{String})
    options = parse_args(args)
    bits = pattern_bits(
        options[:pattern], options[:symbols];
        seed=options[:seed], custom_bits=options[:custom_bits],
    )
    symbols = gray_map_pam4(bits)

    if options[:output] === nothing
        preview_count = min(length(symbols), 16)
        println("pattern=$(options[:pattern]) symbols=$(length(symbols)) seed=$(options[:seed])")
        println("bits:    ", join(bits[1:(2preview_count)]))
        println("symbols: ", join(symbols[1:preview_count], ", "))
    else
        open(options[:output], "w") do io
            println(io, "index,bit0,bit1,symbol")
            for index in eachindex(symbols)
                println(io, index, ',', bits[2index - 1], ',', bits[2index], ',', symbols[index])
            end
        end
        println("wrote $(length(symbols)) symbols to $(options[:output])")
    end
end

try
    main(ARGS)
catch error
    println(stderr, "error: ", sprint(showerror, error))
    usage(stderr)
    exit(1)
end
