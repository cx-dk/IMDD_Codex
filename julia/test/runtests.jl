using SHA
using Test

include(joinpath(@__DIR__, "..", "src", "IMDDPatterns.jl"))
using .IMDDPatterns

function symbol_codes(bits)
    return gray_map_pam4_codes(bits)
end

@testset "Standard PRBS generators" begin
    # IEEE 802.3-2022 120.5.11.2.1 example. The published seed is written
    # S0 first; the integer API stores S0 in its least-significant bit.
    prbs13_seed = 0b1101010100000
    prbs13_example = "1031320220111130103121231210012102121023131112"
    @test join(symbol_codes(generate_prbs(13, 2 * length(prbs13_example); seed=prbs13_seed))) == prbs13_example

    # IEEE 802.3-2022 120.5.11.2.2 example for an all-ones PRBS31 seed.
    prbs31_example = "22222222222222012222222222220002222222222201201222"
    all_ones_31 = (1 << 31) - 1
    @test join(symbol_codes(generate_prbs(31, 2 * length(prbs31_example); seed=all_ones_31))) == prbs31_example

    # Table 68-6 defines d(n) = d(n-9) + d(n-5), modulo 2.
    prbs9 = generate_prbs(9, 1_022; seed=0x1ff)
    @test all(
        index -> prbs9[index] == xor(prbs9[index - 9], prbs9[index - 5]),
        10:length(prbs9),
    )

    # Verify complete maximal periods for the practical short generators.
    for order in (7, 9, 13, 15)
        period = (1 << order) - 1
        sequence = generate_prbs(order, period; seed=1)
        @test count(==(UInt8(1)), sequence) in (div(period, 2), div(period, 2) + 1)
        @test sequence == generate_prbs(order, 2 * period; seed=1)[(period + 1):end]
    end

    @test_throws ArgumentError generate_prbs(8, 10)
    @test_throws ArgumentError generate_prbs(7, 0)
    @test_throws ArgumentError generate_prbs(7, 10; seed=0)
    @test_throws ArgumentError generate_prbs(7, 10; seed=128)
end

@testset "IEEE SSPRQ" begin
    reference_prefix = "2222222222222132222222222221221222222222213213222222222122222122"
    period = ssprq_symbols()

    @test length(period) == 65_535
    @test all(symbol -> symbol in UInt8(0):UInt8(3), period)
    @test join(period[1:length(reference_prefix)]) == reference_prefix
    @test bytes2hex(sha256(period)) == "f17f5effb8e68863e5355258186456e1c3b3c48b5519c1a0c46dac855fae3582"
    @test count(==(UInt8(0)), period) == 15_215
    @test count(==(UInt8(1)), period) == 17_553
    @test count(==(UInt8(2)), period) == 17_552
    @test count(==(UInt8(3)), period) == 15_215

    # The API repeats the fixed standard period and the bit API round-trips
    # through Clause 120 Gray mapping without changing a symbol.
    @test ssprq_symbols(65_540)[65_536:end] == period[1:5]
    @test symbol_codes(pattern_bits("ssprq", 65_535)) == period
    @test_throws ArgumentError ssprq_symbols(0)
end

@testset "Named patterns" begin
    for name in supported_patterns()
        if name != "custom"
            @test length(pattern_bits(name, 17; seed=42)) == 34
        end
    end
    @test pattern_bits("zeros", 3) == zeros(UInt8, 6)
    @test pattern_bits("ones", 3) == ones(UInt8, 6)
    @test pattern_bits("alternating", 3) == UInt8[0, 1, 0, 1, 0, 1]
    @test pattern_bits("custom", 4; custom_bits=[1, 1, 0]) == UInt8[1, 1, 0, 1, 1, 0, 1, 1]
    @test pattern_bits("random", 32; seed=7) == pattern_bits("random", 32; seed=7)
    @test pattern_bits("random", 32; seed=7) != pattern_bits("random", 32; seed=8)
    @test_throws ArgumentError pattern_bits("prbs7q", 4)
    @test_throws ArgumentError pattern_bits("custom", 4)
    @test_throws ArgumentError pattern_bits("unknown", 4)
end

@testset "IEEE PAM4 Gray mapping" begin
    bits = UInt8[0, 0, 0, 1, 1, 1, 1, 0]
    @test gray_map_pam4_codes(bits) == UInt8[0, 1, 2, 3]
    @test gray_map_pam4(bits; normalize=false) == [-3.0, -1.0, 1.0, 3.0]
    @test isapprox(gray_map_pam4(bits), [-1.0, -1 / 3, 1 / 3, 1.0])
    @test isapprox(pattern_symbols("pam4_cycle", 4; seed=1), [-1.0, -1 / 3, 1 / 3, 1.0])
    @test_throws ArgumentError gray_map_pam4(UInt8[0, 1, 0])
    @test_throws ArgumentError gray_map_pam4(UInt8[0, 2])
end
