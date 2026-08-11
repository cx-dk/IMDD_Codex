using Test
include(joinpath(@__DIR__, "..", "src", "IMDDPatterns.jl"))
using .IMDDPatterns

@testset "PRBS generation" begin
    @test generate_prbs(7, 16; seed=1) == UInt8[1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0]
    @test generate_prbs(13, 64; seed=123) == generate_prbs(13, 64; seed=123)
    @test generate_prbs(13, 64; seed=123) != generate_prbs(13, 64; seed=124)
    @test_throws ArgumentError generate_prbs(8, 10)
    @test_throws ArgumentError generate_prbs(7, 0)
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
    @test_throws ArgumentError pattern_bits("custom", 4)
    @test_throws ArgumentError pattern_bits("unknown", 4)
end

@testset "PAM4 Gray mapping" begin
    bits = UInt8[0, 0, 0, 1, 1, 1, 1, 0]
    @test gray_map_pam4(bits; normalize=false) == [-3.0, -1.0, 1.0, 3.0]
    @test gray_map_pam4(bits) ≈ [-1.0, -1 / 3, 1 / 3, 1.0]
    @test pattern_symbols("pam4_cycle", 4; seed=1) ≈ [-1.0, -1 / 3, 1 / 3, 1.0]
    @test_throws ArgumentError gray_map_pam4(UInt8[0, 1, 0])
    @test_throws ArgumentError gray_map_pam4(UInt8[0, 2])
end
