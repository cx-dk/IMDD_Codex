@testset "IMDD transmitter utilities" begin
    @test DbmToWatts(0.0) == 1.0e-3
    @test isapprox(DbmToWatts(3.0), 1.0e-3 * 10.0^0.3)

    symbols = [-1.0, -1 / 3, 1 / 3, 1.0]
    @test OversampleSymbols(symbols, 2) == [
        -1.0, -1.0, -1 / 3, -1 / 3, 1 / 3, 1 / 3, 1.0, 1.0,
    ]
    @test_throws ArgumentError OversampleSymbols(symbols, 0)

    constant_signal = fill(2.5, 64)
    @test LowpassFft(constant_signal, 100.0, 20.0) ≈ constant_signal
    @test LowpassFft(constant_signal, 100.0, 50.0) == constant_signal

    alternating_signal = repeat([1.0, -1.0], 64)
    filtered_signal = LowpassFft(alternating_signal, 128.0, 8.0)
    @test maximum(abs.(filtered_signal)) < 0.01
    @test_throws ArgumentError LowpassFft(alternating_signal, 0.0, 8.0)

    rng_1 = MersenneTwister(7)
    rng_2 = MersenneTwister(7)
    laser_1 = CwLaser(64, 200.0e9, 3.0, 1.0e6, rng_1)
    laser_2 = CwLaser(64, 200.0e9, 3.0, 1.0e6, rng_2)
    @test laser_1 == laser_2
    @test all(isapprox.(abs2.(laser_1), DbmToWatts(3.0)))

    quiet_laser = CwLaser(4, 200.0e9, 0.0, 0.0, MersenneTwister(1))
    @test quiet_laser == fill(ComplexF64(sqrt(1.0e-3)), 4)
    @test AddRin(quiet_laser, 200.0e9, -Inf, MersenneTwister(1)) == quiet_laser
end

@testset "MZM and EML models" begin
    laser_field = fill(1.0 + 0.0im, 4)
    drive = [-1.0, -1 / 3, 1 / 3, 1.0]

    @test MzmModulate(laser_field, zeros(4), 1.0, 2.0, 0.0) == laser_field
    @test_throws ArgumentError MzmModulate(laser_field, drive, 1.0, 0.0, 0.0)

    eml_field = EmlModulate(laser_field, drive, 6.0)
    @test isapprox(abs2(eml_field[1]), 10.0^(-6.0 / 10.0))
    @test isapprox(abs2(eml_field[end]), 1.0)
    @test issorted(abs2.(eml_field))
    @test_throws ArgumentError EmlModulate(laser_field, drive[1:3], 6.0)
end

@testset "Python transmitter model parity" begin
    symbols = [-1.0, -1 / 3, 1 / 3, 1.0]
    drive = OversampleSymbols(symbols, 4)
    filtered_drive = LowpassFft(drive, 212.5e9, 30.0e9)
    expected_drive = [
        -0.3716244395785506, -0.9058158963166814, -1.06196969709173,
        -0.9105650047504502, -0.6198847123048036, -0.3791401763946309,
        -0.2229863756195821, -0.08094414713290402, 0.08094414713290396,
        0.2229863756195821, 0.3791401763946308, 0.6198847123048036,
        0.9105650047504502, 1.06196969709173, 0.9058158963166812,
        0.3716244395785507,
    ]
    @test filtered_drive ≈ expected_drive

    laser_field = fill(ComplexF64(sqrt(DbmToWatts(3.0))), length(filtered_drive))
    optical_field = MzmModulate(laser_field, filtered_drive, 1.0, 2.0, pi / 4)
    expected_field = [
        0.03584265880339906, 0.04060787047522406, 0.04167190877788778,
        0.0406425034830941, 0.03826712277206851, 0.03592117702544986,
        0.03422656286363322, 0.03257316739200816, 0.03056552111482963,
        0.02870199835395861, 0.02655054342334959, 0.02304104228797636,
        0.0185323831601757, 0.01608459927310218, 0.01860814795825488,
        0.02665644621610313,
    ]
    @test real.(optical_field) ≈ expected_field
    @test imag.(optical_field) == zeros(16)
end

@testset "Procedural single-lane transmitter" begin
    result = RunImddTransmitter(
        "pam4_cycle",
        16;
        noise_seed=19,
        samples_per_symbol=4,
        electrical_bandwidth_hz=30.0e9,
        rin_db_hz=-Inf,
    )

    @test result.modulator == "mzm"
    @test result.sample_rate_hz == 4 * result.symbol_rate_hz
    @test result.symbol_codes == repeat(UInt8[0, 1, 2, 3], 4)
    @test result.symbols == repeat([-1.0, -1 / 3, 1 / 3, 1.0], 4)
    @test result.electrical_drive_raw == repeat(result.symbols; inner=4)
    @test length(result.bits) == 32
    @test length(result.optical_field) == 64
    @test result.optical_power_w == abs2.(result.optical_field)

    repeated_result = RunImddTransmitter(
        "pam4_cycle",
        16;
        noise_seed=19,
        samples_per_symbol=4,
        electrical_bandwidth_hz=30.0e9,
        rin_db_hz=-145.0,
        laser_linewidth_hz=1.0e6,
    )
    repeated_result_2 = RunImddTransmitter(
        "pam4_cycle",
        16;
        noise_seed=19,
        samples_per_symbol=4,
        electrical_bandwidth_hz=30.0e9,
        rin_db_hz=-145.0,
        laser_linewidth_hz=1.0e6,
    )
    @test repeated_result.optical_field == repeated_result_2.optical_field

    eml_result = RunImddTransmitter(
        "prbs13q",
        8;
        pattern_seed=1,
        samples_per_symbol=2,
        electrical_bandwidth_hz=0.0,
        rin_db_hz=-Inf,
        modulator="eml",
    )
    @test eml_result.modulator == "eml"
    @test length(eml_result.optical_field) == 16

    @test_throws ArgumentError RunImddTransmitter("prbs13q", 0)
    @test_throws ArgumentError RunImddTransmitter("prbs13q", 8; noise_seed=-1)
    @test_throws ArgumentError RunImddTransmitter("prbs13q", 8; modulator="invalid")
end
