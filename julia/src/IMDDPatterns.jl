module IMDDPatterns

export generate_prbs, gray_map_pam4, pattern_bits, pattern_symbols,
       supported_patterns

const PRBS_TAPS = Dict{Int, Tuple{Vararg{Int}}}(
    7  => (7, 6),
    9  => (9, 5),
    13 => (13, 12, 11, 8),
    15 => (15, 14),
    31 => (31, 28),
)

const SSPRQ_BITS = UInt8[
    0, 0, 0, 0, 1, 1, 1, 1,
    0, 1, 1, 0, 1, 0, 0, 1,
]

"""Return the pattern names accepted by [`pattern_bits`](@ref)."""
supported_patterns() = (
    "prbs7", "prbs9", "prbs13", "prbs13q", "prbs15", "prbs31", "prbs31q",
    "ssprq", "random", "zeros", "ones", "alternating", "pam4_cycle", "custom",
)

"""
    generate_prbs(order, bit_count; seed=1)

Generate a deterministic PRBS bit stream without materializing its complete period.
Supported orders are 7, 9, 13, 15, and 31. A zero seed is replaced with one so
that the LFSR cannot remain in its all-zero lock-up state.
"""
function generate_prbs(order::Integer, bit_count::Integer; seed::Integer=1)::Vector{UInt8}
    haskey(PRBS_TAPS, order) ||
        throw(ArgumentError("unsupported PRBS order $order; choose $(sort!(collect(keys(PRBS_TAPS))))"))
    bit_count > 0 || throw(ArgumentError("bit_count must be positive"))

    width = Int(order)
    mask = (UInt64(1) << width) - UInt64(1)
    state = UInt64(mod(seed, Int128(1) << width)) & mask
    state == 0 && (state = UInt64(1))
    output = Vector{UInt8}(undef, bit_count)

    for index in eachindex(output)
        output[index] = UInt8(state & UInt64(1))
        feedback = UInt64(0)
        for tap in PRBS_TAPS[width]
            feedback ⊻= (state >> (width - tap)) & UInt64(1)
        end
        state = ((state >> 1) | (feedback << (width - 1))) & mask
    end
    return output
end

# SplitMix64 gives `random` an explicitly defined sequence that is reproducible
# across Julia versions and does not add a package dependency.
@inline function splitmix64(state::UInt64)
    next_state = state + UInt64(0x9e3779b97f4a7c15)
    value = next_state
    value = (value ⊻ (value >> 30)) * UInt64(0xbf58476d1ce4e5b9)
    value = (value ⊻ (value >> 27)) * UInt64(0x94d049bb133111eb)
    return next_state, value ⊻ (value >> 31)
end

function random_bits(bit_count::Integer, seed::Integer)::Vector{UInt8}
    state = UInt64(mod(seed, Int128(1) << 64))
    output = Vector{UInt8}(undef, bit_count)
    word = UInt64(0)
    for index in eachindex(output)
        if (index - 1) % 64 == 0
            state, word = splitmix64(state)
        end
        output[index] = UInt8((word >> ((index - 1) % 64)) & UInt64(1))
    end
    return output
end

function repeat_to_length(base::AbstractVector{UInt8}, count::Integer)::Vector{UInt8}
    return [base[mod1(index, length(base))] for index in 1:count]
end

function normalized_name(pattern::AbstractString)::String
    return replace(lowercase(strip(pattern)), '-' => '_', ' ' => '_')
end

"""
    pattern_bits(pattern, symbol_count; seed=1, custom_bits=nothing)

Generate exactly `2 * symbol_count` bits for PAM4 modulation.

Available families are PRBS7/9/13/15/31 (including `prbs13q` and `prbs31q`),
SSPRQ, seeded random data, all-zero/all-one data, alternating 0/1 data, a
four-level Gray PAM4 cycle, and a repeated custom bit sequence.
"""
function pattern_bits(
    pattern::AbstractString,
    symbol_count::Integer;
    seed::Integer=1,
    custom_bits::Union{Nothing, AbstractVector{<:Integer}}=nothing,
)::Vector{UInt8}
    symbol_count > 0 || throw(ArgumentError("symbol_count must be positive"))
    count = 2 * symbol_count
    name = normalized_name(pattern)

    match_result = match(r"^prbs(7|9|13|15|31)q?$", name)
    if match_result !== nothing
        return generate_prbs(parse(Int, match_result.captures[1]), count; seed=seed)
    elseif name == "ssprq"
        return repeat_to_length(SSPRQ_BITS, count)
    elseif name == "random"
        return random_bits(count, seed)
    elseif name in ("zeros", "all_zeros", "all_zero")
        return zeros(UInt8, count)
    elseif name in ("ones", "all_ones", "all_one")
        return ones(UInt8, count)
    elseif name in ("alternating", "clock", "01")
        return repeat_to_length(UInt8[0, 1], count)
    elseif name in ("pam4_cycle", "level_cycle")
        # Gray pairs 00, 01, 11, 10 produce levels -3, -1, +1, +3.
        return repeat_to_length(UInt8[0, 0, 0, 1, 1, 1, 1, 0], count)
    elseif name == "custom"
        custom_bits === nothing &&
            throw(ArgumentError("custom_bits is required for the custom pattern"))
        isempty(custom_bits) && throw(ArgumentError("custom_bits must not be empty"))
        all(bit -> bit in (0, 1), custom_bits) ||
            throw(ArgumentError("custom_bits may contain only 0 and 1"))
        return repeat_to_length(UInt8.(custom_bits), count)
    end

    throw(ArgumentError("unsupported pattern '$pattern'; choose one of $(join(supported_patterns(), ", "))"))
end

"""Map Gray-coded bit pairs 00, 01, 11, 10 to normalized PAM4 levels."""
function gray_map_pam4(bits::AbstractVector{<:Integer}; normalize::Bool=true)::Vector{Float64}
    iseven(length(bits)) || throw(ArgumentError("PAM4 mapping requires an even number of bits"))
    all(bit -> bit in (0, 1), bits) || throw(ArgumentError("bits may contain only 0 and 1"))
    levels = (-3.0, -1.0, 3.0, 1.0) # indexed by binary codes 00, 01, 10, 11
    scale = normalize ? 1 / 3 : 1.0
    symbols = Vector{Float64}(undef, length(bits) ÷ 2)
    for index in eachindex(symbols)
        code = 2 * Int(bits[2index - 1]) + Int(bits[2index])
        symbols[index] = levels[code + 1] * scale
    end
    return symbols
end

"""Generate a named bit pattern and directly map it to PAM4 symbols."""
function pattern_symbols(pattern::AbstractString, symbol_count::Integer; kwargs...)::Vector{Float64}
    return gray_map_pam4(pattern_bits(pattern, symbol_count; kwargs...))
end

end # module IMDDPatterns
