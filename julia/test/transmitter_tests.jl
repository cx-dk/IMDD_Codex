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

    parameters = ImddTransmitterParameters(noise_seed=17)
    @test randn(CreateNoiseRng(parameters, :dac), 16) ==
        randn(CreateNoiseRng(parameters, :dac), 16)
    @test randn(CreateNoiseRng(parameters, :dac), 16) !=
        randn(CreateNoiseRng(parameters, :laser), 16)
    @test CwLaser(64, 200.0e9, 3.0, 1.0e6, parameters) ==
        CwLaser(64, 200.0e9, 3.0, 1.0e6, parameters)
    @test AddRin(quiet_laser, 200.0e9, -145.0, parameters) ==
        AddRin(quiet_laser, 200.0e9, -145.0, parameters)
    @test_throws ArgumentError CreateNoiseRng(parameters, :unknown)
end

@testset "Unified transmitter parameters" begin
    parameters = ImddTransmitterParameters()
    @test parameters.dsp isa ImddDspParameters
    @test parameters.device isa ImddDeviceParameters
    @test propertynames(parameters) == (:noise_seed, :dsp, :device)
    @test parameters.dsp.pattern == "prbs13q"
    @test parameters.device.dac_resolution_bits == 8
    @test parameters.noise_seed == 20260811
    @test !parameters.dsp.tx_nonlinear_compensation_enabled
    @test parameters.dsp.tx_nonlinear_coefficients == [1.0]
    @test parameters.dsp.tx_gain_mode == "adaptive"

    parameters.device.modulator = "eml"
    parameters.device.extinction_ratio_db = 8.0
    parameters.dsp.pattern = "ssprq"
    parameters.dsp.symbol_count = 128
    @test ValidateTransmitterParameters(parameters) === parameters

    separate_parameters = ImddTransmitterParameters()
    @test separate_parameters.device.modulator == "mzm"
    @test separate_parameters.dsp.symbol_count == 1024

    parameters.device.vpi_v = 0.0
    @test_throws ArgumentError ValidateTransmitterParameters(parameters)

    invalid_gain_parameters = ImddTransmitterParameters()
    invalid_gain_parameters.dsp.tx_gain_mode = "automatic"
    @test_throws ArgumentError ValidateTransmitterParameters(invalid_gain_parameters)
    invalid_gain_parameters.dsp.tx_gain_mode = "fixed"
    invalid_gain_parameters.dsp.tx_fixed_gain = 0.0
    @test_throws ArgumentError ValidateTransmitterParameters(invalid_gain_parameters)
end

@testset "Ordinary parameter definition function" begin
    parameters_1 = DefineTransmitterParameters()
    parameters_2 = DefineTransmitterParameters()

    @test parameters_1 isa ImddTransmitterParameters
    @test parameters_1.noise_seed == 20260811
    @test parameters_1.dsp.symbol_count == 4096
    @test parameters_1.device.dac_resolution_bits == 8
    @test parameters_1 !== parameters_2
    @test parameters_1.dsp !== parameters_2.dsp
    @test parameters_1.device !== parameters_2.device
    @test parameters_1.dsp.tx_fir_taps !== parameters_2.dsp.tx_fir_taps

    parameters_1.dsp.symbol_count = 8
    optical_field = RunImddTransmitter(parameters_1)
    @test optical_field isa Vector{ComplexF64}
    @test length(optical_field) ==
        8 * parameters_1.dsp.samples_per_symbol
end

@testset "Independent transmitter DSP" begin
    symbols = [-1.0, -1 / 3, 1 / 3, 1.0]
    @test UpsampleSymbols(symbols, 2) == [-1.0, 0.0, -1 / 3, 0.0, 1 / 3, 0.0, 1.0, 0.0]
    @test_throws ArgumentError UpsampleSymbols(symbols, 0)

    @test ApplyTxFir([1.0, 0.0, 2.0, 0.0], [1.0, 2.0]) == [1.0, 2.0, 2.0, 4.0]
    @test_throws ArgumentError ApplyTxFir([1.0], Float64[])

    nonlinear_input = [-2.0, -1.0, 0.0, 1.0, 2.0]
    nonlinear_expected = nonlinear_input .+ 0.5 .* nonlinear_input .^ 3
    @test ApplyTxNonlinearCompensation(nonlinear_input, [1.0, 0.0, 0.5]) ==
        nonlinear_expected
    @test ApplyTxNonlinearCompensation(nonlinear_input, [1.0]) == nonlinear_input
    @test_throws ArgumentError ApplyTxNonlinearCompensation(nonlinear_input, Float64[])

    dsp = ImddDspParameters(
        pattern="pam4_cycle",
        symbol_count=4,
        samples_per_symbol=4,
    )
    @test RunTxDsp(dsp) == repeat(symbols; inner=4)

    dsp.tx_fir_taps = [1.0, 0.5]
    expected = ApplyTxFir(UpsampleSymbols(symbols, 4), dsp.tx_fir_taps)
    @test RunTxDsp(dsp) == expected
    @test length(expected) == dsp.symbol_count * dsp.samples_per_symbol

    dsp.tx_nonlinear_compensation_enabled = true
    dsp.tx_nonlinear_coefficients = [1.0, 0.0, 0.25]
    @test RunTxDsp(dsp) ==
        ApplyTxNonlinearCompensation(expected, dsp.tx_nonlinear_coefficients)
end

@testset "Adaptive DAC input gain" begin
    @test CalculateOptimalTxGain([-0.25, 0.25], 2) == 4.0
    @test CalculateOptimalTxGain([-1.0, -1 / 3, 1 / 3, 1.0], 2) == 1.0
    @test CalculateOptimalTxGain(zeros(16), 8) == 1.0
    @test CalculateOptimalTxGain([-0.5, 0.5], 8; max_samples=1) > 0.0
    @test_throws ArgumentError CalculateOptimalTxGain(Float64[], 8)
    @test_throws ArgumentError CalculateOptimalTxGain([1.0], 0)
    @test_throws ArgumentError CalculateOptimalTxGain([1.0], 8; search_points=2)
end

@testset "DAC model" begin
    pam4_levels = [-1.0, -1 / 3, 1 / 3, 1.0]
    @test QuantizeDac(pam4_levels, 8) ≈ pam4_levels
    @test QuantizeDac([-2.0, 2.0], 8) == [-1.0, 1.0]
    @test QuantizeDac(pam4_levels, 2) ≈ pam4_levels
    @test_throws ArgumentError QuantizeDac(pam4_levels, 0)
    @test_throws ArgumentError QuantizeDac(pam4_levels, 8; full_scale=0.0)

    held_signal = OversampleSymbols(pam4_levels, 4)
    @test ApplyDacJitter(held_signal, 4, 0.0, MersenneTwister(1)) == held_signal
    @test_throws ArgumentError ApplyDacJitter(held_signal, 4, -0.01, MersenneTwister(1))

    dac_input = OversampleSymbols(pam4_levels, 4)
    ideal_dac = GenerateDacWaveform(
        dac_input;
        sample_rate_hz=212.5e9,
        samples_per_symbol=4,
        resolution_bits=8,
        bandwidth_hz=0.0,
    )
    @test ideal_dac ≈ dac_input

    dac_1 = GenerateDacWaveform(
        dac_input;
        sample_rate_hz=212.5e9,
        samples_per_symbol=4,
        resolution_bits=8,
        jitter_rms_ui=0.01,
        noise_rms=0.002,
        bandwidth_hz=30.0e9,
        rng=MersenneTwister(11),
    )
    dac_2 = GenerateDacWaveform(
        dac_input;
        sample_rate_hz=212.5e9,
        samples_per_symbol=4,
        resolution_bits=8,
        jitter_rms_ui=0.01,
        noise_rms=0.002,
        bandwidth_hz=30.0e9,
        rng=MersenneTwister(11),
    )
    @test dac_1 == dac_2
    @test length(dac_1) == length(dac_input)
    @test dac_1 != ideal_dac
    @test_throws ArgumentError GenerateDacWaveform(dac_input; noise_rms=-1.0)
end

@testset "MZM and EML models" begin
    laser_field = fill(1.0 + 0.0im, 4)
    drive = [-1.0, -1 / 3, 1 / 3, 1.0]

    @test MzmModulate(laser_field, zeros(4), 1.0, 2.0, 0.0, Inf) == laser_field
    @test_throws ArgumentError MzmModulate(laser_field, drive, 1.0, 0.0, 0.0, 6.0)

    maximum_field = MzmModulate(laser_field, zeros(4), 0.0, 2.0, 0.0, 20.0)
    minimum_field = MzmModulate(laser_field, zeros(4), 0.0, 2.0, pi / 2, 20.0)
    @test abs2.(maximum_field) ≈ ones(4)
    @test abs2.(minimum_field) ≈ fill(0.01, 4)
    @test_throws ArgumentError MzmModulate(
        laser_field,
        drive,
        1.0,
        2.0,
        0.0,
        -1.0,
    )

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
    optical_field = MzmModulate(laser_field, filtered_drive, 1.0, 2.0, pi / 4, Inf)
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
    parameters = ImddTransmitterParameters()
    parameters.dsp.pattern = "pam4_cycle"
    parameters.dsp.symbol_count = 16
    parameters.noise_seed = 19
    parameters.dsp.samples_per_symbol = 4
    parameters.device.electrical_bandwidth_hz = 30.0e9
    parameters.device.rin_db_hz = -Inf
    optical_field = RunImddTransmitter(parameters)

    tx_dsp_output = RunTxDsp(parameters.dsp)
    adaptive_gain = CalculateOptimalTxGain(
        tx_dsp_output,
        parameters.device.dac_resolution_bits;
        full_scale=parameters.device.dac_full_scale,
        search_span_db=parameters.dsp.tx_gain_search_span_db,
        search_points=parameters.dsp.tx_gain_search_points,
        max_samples=parameters.dsp.tx_gain_max_samples,
    )
    expected_dac_output = LowpassFft(
        QuantizeDac(
            adaptive_gain .* tx_dsp_output,
            parameters.device.dac_resolution_bits;
            full_scale=parameters.device.dac_full_scale,
        ),
        parameters.dsp.symbol_rate_hz * parameters.dsp.samples_per_symbol,
        parameters.device.electrical_bandwidth_hz;
        order=parameters.device.filter_order,
    )
    expected_laser_field = fill(
        ComplexF64(sqrt(DbmToWatts(parameters.device.laser_power_dbm))),
        length(expected_dac_output),
    )
    expected_optical_field = MzmModulate(
        expected_laser_field,
        expected_dac_output,
        parameters.device.drive_vpp,
        parameters.device.vpi_v,
        parameters.device.bias_phase_rad,
        parameters.device.extinction_ratio_db,
        parameters.device.chirp,
    )
    @test optical_field isa Vector{ComplexF64}
    @test length(optical_field) == 64
    @test optical_field ≈ expected_optical_field
    @test RunTxDevice(tx_dsp_output, parameters) ≈ optical_field

    noisy_parameters = deepcopy(parameters)
    noisy_parameters.device.dac_noise_rms = 0.002
    repeated_result = RunImddTransmitter(noisy_parameters)
    repeated_result_2 = RunImddTransmitter(noisy_parameters)
    @test repeated_result == repeated_result_2
    @test repeated_result != optical_field
    changed_seed_parameters = deepcopy(noisy_parameters)
    changed_seed_parameters.noise_seed += 1
    @test RunImddTransmitter(changed_seed_parameters) != repeated_result

    custom_fir_parameters = deepcopy(parameters)
    custom_fir_parameters.dsp.tx_fir_taps = [1.0, 0.5]
    @test RunImddTransmitter(custom_fir_parameters) != optical_field

    fixed_gain_parameters = deepcopy(parameters)
    fixed_gain_parameters.dsp.tx_gain_mode = "fixed"
    fixed_gain_parameters.dsp.tx_fixed_gain = 0.5
    fixed_gain_output = RunImddTransmitter(fixed_gain_parameters)
    fixed_gain_dac_expected = LowpassFft(
        QuantizeDac(
            0.5 .* RunTxDsp(fixed_gain_parameters.dsp),
            fixed_gain_parameters.device.dac_resolution_bits;
            full_scale=fixed_gain_parameters.device.dac_full_scale,
        ),
        fixed_gain_parameters.dsp.symbol_rate_hz *
            fixed_gain_parameters.dsp.samples_per_symbol,
        fixed_gain_parameters.device.electrical_bandwidth_hz;
        order=fixed_gain_parameters.device.filter_order,
    )
    fixed_gain_laser = fill(
        ComplexF64(sqrt(DbmToWatts(fixed_gain_parameters.device.laser_power_dbm))),
        length(fixed_gain_dac_expected),
    )
    fixed_gain_expected = MzmModulate(
        fixed_gain_laser,
        fixed_gain_dac_expected,
        fixed_gain_parameters.device.drive_vpp,
        fixed_gain_parameters.device.vpi_v,
        fixed_gain_parameters.device.bias_phase_rad,
        fixed_gain_parameters.device.extinction_ratio_db,
        fixed_gain_parameters.device.chirp,
    )
    @test fixed_gain_output ≈ fixed_gain_expected
    @test fixed_gain_output != optical_field

    nonlinear_parameters = deepcopy(parameters)
    nonlinear_parameters.dsp.tx_nonlinear_compensation_enabled = true
    nonlinear_parameters.dsp.tx_nonlinear_coefficients = [1.0, 0.0, 0.2]
    @test RunImddTransmitter(nonlinear_parameters) != optical_field

    eml_parameters = deepcopy(parameters)
    eml_parameters.device.modulator = "eml"
    eml_output = RunImddTransmitter(eml_parameters)
    @test eml_output == EmlModulate(
        expected_laser_field,
        expected_dac_output,
        eml_parameters.device.extinction_ratio_db,
        eml_parameters.device.chirp,
    )
    @test eml_output != optical_field

    @test_throws ArgumentError RunTxDevice(Float64[], parameters)
    @test_throws ArgumentError RunTxDevice([NaN], parameters)

    invalid_parameters = ImddTransmitterParameters()
    invalid_parameters.dsp.symbol_count = 0
    @test_throws ArgumentError RunImddTransmitter(invalid_parameters)
    invalid_parameters.dsp.symbol_count = 8
    invalid_parameters.noise_seed = -1
    @test_throws ArgumentError RunImddTransmitter(invalid_parameters)
    invalid_parameters.noise_seed = 1
    invalid_parameters.device.dac_resolution_bits = 0
    @test_throws ArgumentError RunImddTransmitter(invalid_parameters)
    invalid_parameters.device.dac_resolution_bits = 8
    invalid_parameters.dsp.tx_fir_taps = [NaN]
    @test_throws ArgumentError RunImddTransmitter(invalid_parameters)
    invalid_parameters.dsp.tx_fir_taps = Float64[]
    invalid_parameters.dsp.tx_nonlinear_coefficients = Float64[]
    @test_throws ArgumentError RunImddTransmitter(invalid_parameters)
end
