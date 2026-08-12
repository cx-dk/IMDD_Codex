module IMDDPatterns

export GeneratePrbs, GrayMapPam4, GrayMapPam4Codes, PatternBits, PatternSymbols,
       SsprqSymbols, SupportedPatterns

# Register taps are numbered S0 through S(order-1). On every update the
# feedback bit enters S0 and the old Si moves to S(i+1). The tuples below
# implement the generator polynomials used by the named PRBS patterns.
const PRBS_FEEDBACK_TAPS = Dict{Int, Tuple{Vararg{Int}}}(
    7  => (5, 6),          # 1 + x^6 + x^7
    9  => (4, 8),          # 1 + x^5 + x^9; IEEE 802.3 Table 68-6
    13 => (0, 1, 11, 12),  # 1 + x + x^2 + x^12 + x^13; Figure 94-6
    15 => (13, 14),        # 1 + x^14 + x^15
    31 => (27, 30),        # 1 + x^28 + x^31; Figure 49-9
)

const SSPRQ_PERIOD_SYMBOLS = 65_535
const SSPRQ_SECTIONS = (
    (seed=0x00000002, length=10_924),
    (seed=0x34013ff7, length=10_922),
    (seed=0x0ccccccc, length=10_922),
)

"""Return the pattern names accepted by [`PatternBits`](@ref)."""
SupportedPatterns() = (
    "prbs7", "prbs9", "prbs13", "prbs13q", "prbs15", "prbs31", "prbs31q",
    "ssprq", "random", "zeros", "ones", "alternating", "pam4_cycle", "custom",
)

@inline function FeedbackBit(state::UInt64, taps::Tuple{Vararg{Int}})::UInt8
    feedback = UInt8(0)
    for tap in taps
        feedback = xor(feedback, UInt8((state >> tap) & UInt64(1)))
    end
    return feedback
end

"""
    GeneratePrbs(order, bit_count; seed=1)

Generate a PRBS bit stream using the standard polynomial for `order`.

The integer seed presets register `Si` from bit `i`, so its least-significant
bit presets `S0`. The seed must fit the register and must not be zero. PRBS31
uses the inverted output required by IEEE 802.3 Figure 49-9; PRBS13 uses the
four-tap generator in Figure 94-6. Supported orders are 7, 9, 13, 15, and 31.
"""
function GeneratePrbs(order::Integer, bit_count::Integer; seed::Integer=1)::Vector{UInt8}
    haskey(PRBS_FEEDBACK_TAPS, order) ||
        throw(ArgumentError("unsupported PRBS order $order; choose $(sort!(collect(keys(PRBS_FEEDBACK_TAPS))))"))
    bit_count > 0 || throw(ArgumentError("bit_count must be positive"))

    width = Int(order)
    mask = (UInt64(1) << width) - UInt64(1)
    0 < seed <= mask ||
        throw(ArgumentError("seed must be in 1:$(Int(mask)) for PRBS$order"))

    state = UInt64(seed)
    taps = PRBS_FEEDBACK_TAPS[width]
    output = Vector{UInt8}(undef, bit_count)
    for index in eachindex(output)
        feedback = FeedbackBit(state, taps)
        # IEEE 802.3 Figure 49-9 takes the inverted feedback as PRBS31 output.
        output[index] = width == 31 ? xor(feedback, UInt8(1)) : feedback
        state = ((state << 1) & mask) | UInt64(feedback)
    end
    return output
end

"""
    GrayMapPam4Codes(bits)

Map ordered bit pairs to IEEE 802.3 PAM4 symbol codes: `00 -> 0`, `01 -> 1`,
`11 -> 2`, and `10 -> 3`.
"""
function GrayMapPam4Codes(bits::AbstractVector{<:Integer})::Vector{UInt8}
    iseven(length(bits)) || throw(ArgumentError("PAM4 mapping requires an even number of bits"))
    all(bit -> bit in (0, 1), bits) || throw(ArgumentError("bits may contain only 0 and 1"))

    # Indexed by the binary value of the ordered pair: 00, 01, 10, 11.
    gray_codes = UInt8[0, 1, 3, 2]
    symbols = Vector{UInt8}(undef, div(length(bits), 2))
    for index in eachindex(symbols)
        binary_code = 2 * Int(bits[2 * index - 1]) + Int(bits[2 * index])
        symbols[index] = gray_codes[binary_code + 1]
    end
    return symbols
end

function GraySymbolBits(symbols::AbstractVector{<:Integer})::Vector{UInt8}
    all(symbol -> symbol in 0:3, symbols) ||
        throw(ArgumentError("PAM4 symbols must be in 0:3"))
    # Symbol codes 0, 1, 2, 3 map back to 00, 01, 11, 10.
    pairs = ((0, 0), (0, 1), (1, 1), (1, 0))
    bits = Vector{UInt8}(undef, 2 * length(symbols))
    for index in eachindex(symbols)
        first_bit, second_bit = pairs[Int(symbols[index]) + 1]
        bits[2 * index - 1] = first_bit
        bits[2 * index] = second_bit
    end
    return bits
end

function BuildSsprqPeriod()::Vector{UInt8}
    # IEEE 802.3-2022, 120.5.11.2.3 and Table 120-2.
    sequence_a = reduce(
        vcat,
        (
            GeneratePrbs(31, section.length; seed=section.seed)
            for section in SSPRQ_SECTIONS
        ),
    )
    @assert length(sequence_a) == 32_768

    repeated_a = vcat(sequence_a, sequence_a)
    sequence_b = repeated_a[2:(end - 1)]
    @assert length(sequence_b) == 65_534

    sequence_1 = GrayMapPam4Codes(sequence_a)
    sequence_2 = UInt8.(3 .- GrayMapPam4Codes(sequence_a))
    sequence_3 = GrayMapPam4Codes(sequence_b[1:32_766])
    sequence_4 = UInt8.(3 .- GrayMapPam4Codes(sequence_b[(end - 32_767):end]))
    symbols = vcat(sequence_1, sequence_2, sequence_3, sequence_4)
    @assert length(symbols) == SSPRQ_PERIOD_SYMBOLS
    return symbols
end

# The standard SSPRQ period is fixed. Keep the private cached vector immutable
# by returning copies/repetitions from the public API.
const SSPRQ_SYMBOL_PERIOD = BuildSsprqPeriod()

"""
    SsprqSymbols(symbol_count=65535)

Return IEEE 802.3-2022 Clause 120 SSPRQ symbol codes (`0` through `3`). The
fixed 65535-symbol standard period is repeated or truncated to `symbol_count`.
"""
function SsprqSymbols(symbol_count::Integer=SSPRQ_PERIOD_SYMBOLS)::Vector{UInt8}
    symbol_count > 0 || throw(ArgumentError("symbol_count must be positive"))
    return RepeatToLength(SSPRQ_SYMBOL_PERIOD, symbol_count)
end

# SplitMix64 gives `random` an explicitly defined sequence that is reproducible
# across Julia versions and does not add a package dependency.
@inline function SplitMix64(state::UInt64)
    next_state = state + UInt64(0x9e3779b97f4a7c15)
    value = next_state
    value = xor(value, value >> 30) * UInt64(0xbf58476d1ce4e5b9)
    value = xor(value, value >> 27) * UInt64(0x94d049bb133111eb)
    return next_state, xor(value, value >> 31)
end

function RandomBits(bit_count::Integer, seed::Integer)::Vector{UInt8}
    state = UInt64(mod(seed, Int128(1) << 64))
    output = Vector{UInt8}(undef, bit_count)
    word = UInt64(0)
    for index in eachindex(output)
        if (index - 1) % 64 == 0
            state, word = SplitMix64(state)
        end
        output[index] = UInt8((word >> ((index - 1) % 64)) & UInt64(1))
    end
    return output
end

function RepeatToLength(base::AbstractVector{T}, count::Integer)::Vector{T} where {T}
    isempty(base) && throw(ArgumentError("base sequence must not be empty"))
    return [base[mod1(index, length(base))] for index in 1:count]
end

function NormalizedName(pattern::AbstractString)::String
    return replace(lowercase(strip(pattern)), '-' => '_', ' ' => '_')
end

"""
    PatternBits(pattern, symbol_count; seed=1, custom_bits=nothing)

Generate exactly `2 * symbol_count` bits for PAM4 modulation. `prbs13q`,
`prbs31q`, and `ssprq` follow IEEE 802.3-2022 Clause 120. The plain PRBS
names use their standard binary polynomials and are paired for PAM4 by this
PAM4-oriented API. Fixed, random, alternating, cycle, and custom patterns are
engineering conveniences rather than IEEE compliance patterns.
"""
function PatternBits(
    pattern::AbstractString,
    symbol_count::Integer;
    seed::Integer=1,
    custom_bits::Union{Nothing, AbstractVector{<:Integer}}=nothing,
)::Vector{UInt8}
    symbol_count > 0 || throw(ArgumentError("symbol_count must be positive"))
    count = 2 * symbol_count
    name = NormalizedName(pattern)

    if name in ("prbs7", "prbs9", "prbs13", "prbs13q", "prbs15", "prbs31", "prbs31q")
        order_match = match(r"^prbs(7|9|13|15|31)q?$", name)
        return GeneratePrbs(parse(Int, order_match.captures[1]), count; seed=seed)
    elseif name == "ssprq"
        return GraySymbolBits(SsprqSymbols(symbol_count))
    elseif name == "random"
        return RandomBits(count, seed)
    elseif name in ("zeros", "all_zeros", "all_zero")
        return zeros(UInt8, count)
    elseif name in ("ones", "all_ones", "all_one")
        return ones(UInt8, count)
    elseif name in ("alternating", "clock", "01")
        return RepeatToLength(UInt8[0, 1], count)
    elseif name in ("pam4_cycle", "level_cycle")
        # Gray pairs 00, 01, 11, 10 produce levels -3, -1, +1, +3.
        return RepeatToLength(UInt8[0, 0, 0, 1, 1, 1, 1, 0], count)
    elseif name == "custom"
        custom_bits === nothing &&
            throw(ArgumentError("custom_bits is required for the custom pattern"))
        isempty(custom_bits) && throw(ArgumentError("custom_bits must not be empty"))
        all(bit -> bit in (0, 1), custom_bits) ||
            throw(ArgumentError("custom_bits may contain only 0 and 1"))
        return RepeatToLength(UInt8.(custom_bits), count)
    end

    throw(ArgumentError("unsupported pattern '$pattern'; choose one of $(join(SupportedPatterns(), ", "))"))
end

"""
    GrayMapPam4(bits; normalize=true)

Map ordered bit pairs according to IEEE 802.3-2022 120.5.7.1: `00 -> 0`,
`01 -> 1`, `11 -> 2`, and `10 -> 3`. By default the symbol codes are converted
to normalized electrical levels `-1`, `-1/3`, `1/3`, and `1`.
"""
function GrayMapPam4(bits::AbstractVector{<:Integer}; normalize::Bool=true)::Vector{Float64}
    symbols = GrayMapPam4Codes(bits)
    if normalize
        return (2.0 .* Float64.(symbols) .- 3.0) ./ 3.0
    end
    return 2.0 .* Float64.(symbols) .- 3.0
end

"""Generate a named bit pattern and directly map it to PAM4 levels."""
function PatternSymbols(pattern::AbstractString, symbol_count::Integer; kwargs...)::Vector{Float64}
    return GrayMapPam4(PatternBits(pattern, symbol_count; kwargs...))
end

end # module IMDDPatterns
