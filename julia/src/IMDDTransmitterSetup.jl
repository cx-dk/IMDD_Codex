"""
    DefineTransmitterParameters()

Define one complete set of IMDD transmitter parameters in an ordinary Julia
function and return an `ImddTransmitterParameters` object.

Edit the values in this function when configuring a simulation. Keeping the
configuration in a function ensures that every call creates fresh parameter
objects and coefficient vectors. The returned object can be passed directly
to `ValidateTransmitterParameters`, `RunTxDsp`, `RunTxDevice`, or
`RunImddTransmitter`.

The comments beside each field describe its unit, valid values, enable/bypass
condition, and position in the processing chain. `RunImddTransmitter` executes
both the DSP and device sections and returns the final complex optical field.

# Returns

An independent mutable `ImddTransmitterParameters` object containing the
master noise seed, DSP parameters, and device parameters.
"""
function DefineTransmitterParameters()::ImddTransmitterParameters
    # -------------------------------------------------------------------------
    # Global noise configuration
    # -------------------------------------------------------------------------
    # Non-negative master seed for every stochastic device model. The code
    # derives independent :dac, :laser, and :rin streams from this one value,
    # so changing or disabling one noise source does not shift another source.
    # Reusing the same seed and all other parameters reproduces the waveform.
    noise_seed = 20260811

    # -------------------------------------------------------------------------
    # Transmitter DSP configuration
    # -------------------------------------------------------------------------
    dsp_parameters = ImddDspParameters(
        # ---------------------------------------------------------------------
        # Pattern and sample grid
        # ---------------------------------------------------------------------
        # Supported values are returned by SupportedPatterns(). Common choices:
        #   IEEE:       "prbs9", "prbs13q", "prbs31q", "ssprq"
        #   Engineering:"random", "zeros", "ones", "alternating",
        #               "pam4_cycle", "custom"
        pattern="prbs13q",

        # Positive number of PAM4 symbols. The Tx DSP output contains
        # symbol_count * samples_per_symbol samples.
        symbol_count=4096,

        # Pattern seed. PRBS seeds must be nonzero and fit the selected LFSR;
        # "random" uses this seed for reproducible data. SSPRQ and fixed
        # engineering patterns ignore it. This seed does not control noise.
        pattern_seed=1,

        # Used only when pattern="custom". Supply a non-empty binary UInt8
        # vector, for example UInt8[0, 0, 0, 1, 1, 1, 1, 0]. The vector repeats
        # or truncates to the required two bits per PAM4 symbol.
        custom_bits=nothing,

        # Positive PAM4 symbol rate in baud (symbols/s).
        symbol_rate_hz=53.125e9,

        # Positive integer transmitter oversampling ratio. The DAC sample rate
        # is symbol_rate_hz * samples_per_symbol.
        samples_per_symbol=4,

        # ---------------------------------------------------------------------
        # Sample-spaced TxFIR
        # ---------------------------------------------------------------------
        # Finite coefficients operating at the oversampled DAC rate. The first
        # tap multiplies the current sample; later taps multiply older samples.
        # Float64[] selects ones(samples_per_symbol), which converts the
        # zero-insertion upsampled symbols into a rectangular held waveform.
        # Example custom pulse shape: [0.1, 0.4, 1.0, 0.4, 0.1].
        tx_fir_taps=Float64[],

        # ---------------------------------------------------------------------
        # Optional memoryless polynomial compensation:
        # y = c1*x + c2*x^2 + ... + cn*x^n.
        # ---------------------------------------------------------------------
        # false bypasses compensation; true applies it after TxFIR and before
        # DAC gain control. Use it to approximate the inverse static transfer
        # curve of a DAC, driver, or optical modulator.
        tx_nonlinear_compensation_enabled=false,

        # Non-empty finite polynomial coefficients with no constant term.
        # Index k is the coefficient of x^k. [1.0] is an exact identity;
        # [1.0, 0.0, 0.1] implements x + 0.1*x^3.
        tx_nonlinear_coefficients=[1.0],

        # ---------------------------------------------------------------------
        # DAC-input gain control
        # ---------------------------------------------------------------------
        # "adaptive": search for a positive gain that minimizes input-referred
        # quantization/clipping MSE. "fixed": apply tx_fixed_gain directly.
        tx_gain_mode="adaptive",

        # Finite positive linear gain used only when tx_gain_mode="fixed".
        # A value below 1 reduces amplitude; a value above 1 increases it.
        tx_fixed_gain=1.0,

        # Finite positive total adaptive search span in dB, centered on the
        # peak-fitting gain dac_full_scale / maximum(abs, tx_dsp_output).
        tx_gain_search_span_db=24.0,

        # Number of logarithmically spaced adaptive gain candidates; >= 3.
        # More points improve resolution but increase calculation time.
        tx_gain_search_points=129,

        # Positive maximum number of deterministically decimated samples used
        # by the gain cost function. It bounds runtime for long patterns.
        tx_gain_max_samples=65_536,
    )

    # -------------------------------------------------------------------------
    # Transmitter device configuration
    # -------------------------------------------------------------------------
    device_parameters = ImddDeviceParameters(
        # ---------------------------------------------------------------------
        # DAC / driver parameters used by RunTxDevice
        # ---------------------------------------------------------------------
        # Integer uniform-DAC resolution in bits, valid range 1:52. The model
        # has 2^dac_resolution_bits equally spaced levels including endpoints.
        dac_resolution_bits=8,

        # Finite positive normalized DAC peak magnitude. Values outside
        # [-dac_full_scale, +dac_full_scale] clip before quantization.
        dac_full_scale=1.0,

        # Finite non-negative Gaussian aperture-jitter RMS in unit intervals.
        # 0 disables jitter. Jitter is applied before clipping/quantization.
        dac_jitter_rms_ui=0.0,

        # Finite non-negative additive DAC output-noise RMS in normalized
        # amplitude. 0 disables it. Noise is added after quantization and
        # before the reconstruction low-pass filter.
        dac_noise_rms=0.0,

        # Finite non-negative electrical reconstruction-filter -3 dB bandwidth
        # in Hz. 0 or a value at/above sample_rate/2 bypasses the filter.
        electrical_bandwidth_hz=30.0e9,

        # Positive order of the zero-phase Butterworth-like magnitude response.
        # Larger values create a steeper transition around the bandwidth.
        filter_order=4,

        # ---------------------------------------------------------------------
        # Laser parameters used by RunTxDevice through CwLaser and AddRin.
        # ---------------------------------------------------------------------
        # Finite positive optical carrier wavelength in nanometres.
        wavelength_nm=1311.0,

        # Finite average CW laser output power in dBm.
        laser_power_dbm=3.0,

        # Finite non-negative Lorentzian linewidth in Hz. 0 disables the
        # Wiener phase-noise process in CwLaser.
        laser_linewidth_hz=0.0,

        # One-sided relative-intensity-noise density in dB/Hz. Use -Inf to
        # disable RIN exactly. NaN is invalid.
        rin_db_hz=-145.0,

        # ---------------------------------------------------------------------
        # Optical modulator parameters used by RunTxDevice.
        # ---------------------------------------------------------------------
        # Supported model selector: "mzm" or "eml".
        modulator="mzm",

        # Finite non-negative peak-to-peak electrical drive voltage in volts.
        drive_vpp=1.0,

        # Finite positive MZM half-wave voltage in volts. Used by MZM only.
        vpi_v=2.0,

        # Finite MZM operating-point phase in radians. pi/4 is quadrature bias.
        bias_phase_rad=pi / 4,

        # Finite dimensionless optical chirp coefficient. 0 disables chirp.
        chirp=0.0,

        # Non-negative modulator extinction ratio in dB. Finite values model
        # residual minimum transmission; Inf selects an ideal MZM null.
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
