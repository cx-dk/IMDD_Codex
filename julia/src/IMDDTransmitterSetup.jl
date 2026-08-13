"""
    DefineTransmitterParameters()

Define one complete set of IMDD transmitter parameters in an ordinary Julia
function and return an `ImddTransmitterParameters` object.

Edit the values in this function when configuring a simulation. Keeping the
configuration in a function ensures that every call creates fresh parameter
objects and coefficient vectors. The returned object can be passed directly
to `ValidateTransmitterParameters`, `RunTxDsp`, or `RunImddTransmitter`.

# Returns

An independent mutable `ImddTransmitterParameters` object containing the
master noise seed, DSP parameters, and device parameters.
"""
function DefineTransmitterParameters()::ImddTransmitterParameters
    # -------------------------------------------------------------------------
    # Global noise configuration
    # -------------------------------------------------------------------------
    noise_seed = 20260811

    # -------------------------------------------------------------------------
    # Transmitter DSP configuration
    # -------------------------------------------------------------------------
    dsp_parameters = ImddDspParameters(
        # Pattern and sample grid
        pattern="prbs13q",
        symbol_count=4096,
        pattern_seed=1,
        custom_bits=nothing,
        symbol_rate_hz=53.125e9,
        samples_per_symbol=4,

        # Sample-spaced TxFIR. Empty selects ones(samples_per_symbol).
        tx_fir_taps=Float64[],

        # Optional memoryless polynomial compensation:
        # y = c1*x + c2*x^2 + ... + cn*x^n.
        tx_nonlinear_compensation_enabled=false,
        tx_nonlinear_coefficients=[1.0],

        # DAC-input gain control: "adaptive" or "fixed".
        tx_gain_mode="adaptive",
        tx_fixed_gain=1.0,
        tx_gain_search_span_db=24.0,
        tx_gain_search_points=129,
        tx_gain_max_samples=65_536,
    )

    # -------------------------------------------------------------------------
    # Transmitter device configuration
    # -------------------------------------------------------------------------
    device_parameters = ImddDeviceParameters(
        # DAC / driver
        dac_resolution_bits=8,
        dac_full_scale=1.0,
        dac_jitter_rms_ui=0.0,
        dac_noise_rms=0.0,
        electrical_bandwidth_hz=30.0e9,
        filter_order=4,

        # Laser
        wavelength_nm=1311.0,
        laser_power_dbm=3.0,
        laser_linewidth_hz=0.0,
        rin_db_hz=-145.0,

        # Modulator: "mzm" or "eml".
        modulator="mzm",
        drive_vpp=1.0,
        vpi_v=2.0,
        bias_phase_rad=pi / 4,
        chirp=0.0,
        extinction_ratio_db=6.0,
    )

    parameters = ImddTransmitterParameters(
        noise_seed=noise_seed,
        dsp=dsp_parameters,
        device=device_parameters,
    )
    ValidateTransmitterParameters(parameters)
    return parameters
end
