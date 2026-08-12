import hashlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import numpy as np

from imdd_sim.dsp.mlse import mlse_detect
from imdd_sim.config import MeasuredS21Config
from imdd_sim.models.fiber import propagate_fiber, propagate_wdm_channels
from imdd_sim.models.measured_response import apply_measured_s21, load_measured_s21
from imdd_sim.models.signal import (
    generate_prbs,
    gray_demap_pam4,
    gray_map_pam4,
    gray_map_pam4_codes,
    pam4_decisions,
    pattern_bits,
    ssprq_symbols,
)


class SignalModelTests(unittest.TestCase):
    def test_gray_pam4_round_trip(self) -> None:
        bits = np.array([0, 0, 0, 1, 1, 1, 1, 0], dtype=np.uint8)
        symbols = gray_map_pam4(bits)
        np.testing.assert_array_equal(gray_map_pam4_codes(bits), [0, 1, 2, 3])
        np.testing.assert_allclose(symbols, [-1.0, -1 / 3, 1 / 3, 1.0])
        recovered = gray_demap_pam4(pam4_decisions(symbols * 3.0))
        np.testing.assert_array_equal(recovered, bits)

    def test_ieee_prbs13q_published_example(self) -> None:
        seed = 0b1101010100000
        expected_codes = "1031320220111130103121231210012102121023131112"
        bits = generate_prbs(13, 2 * len(expected_codes), seed)
        actual_codes = "".join(str(value) for value in gray_map_pam4_codes(bits))
        self.assertEqual(actual_codes, expected_codes)

    def test_ieee_prbs31q_published_example(self) -> None:
        expected_codes = "22222222222222012222222222220002222222222201201222"
        bits = generate_prbs(31, 2 * len(expected_codes), (1 << 31) - 1)
        actual_codes = "".join(str(value) for value in gray_map_pam4_codes(bits))
        self.assertEqual(actual_codes, expected_codes)

    def test_ieee_ssprq_complete_period(self) -> None:
        period = ssprq_symbols()
        expected_prefix = "2222222222222132222222222221221222222222213213222222222122222122"
        self.assertEqual(period.size, 65_535)
        self.assertEqual("".join(str(value) for value in period[: len(expected_prefix)]), expected_prefix)
        self.assertEqual(
            hashlib.sha256(period.tobytes()).hexdigest(),
            "f17f5effb8e68863e5355258186456e1c3b3c48b5519c1a0c46dac855fae3582",
        )
        np.testing.assert_array_equal(
            np.bincount(period, minlength=4),
            [15_215, 17_553, 17_552, 15_215],
        )
        np.testing.assert_array_equal(
            gray_map_pam4_codes(pattern_bits("ssprq", period.size)),
            period,
        )

    def test_prbs_seed_is_not_silently_masked(self) -> None:
        with self.assertRaisesRegex(ValueError, "seed must be"):
            generate_prbs(13, 16, 1 << 13)

    def test_fiber_attenuation(self) -> None:
        field = np.ones(1024, dtype=np.complex128)
        result = propagate_fiber(
            field,
            sample_rate_hz=100e9,
            length_m=2000.0,
            attenuation_db_km=0.5,
            dispersion_ps_nm_km=0.0,
            wavelength_nm=1311.0,
        )
        measured_power_ratio = np.mean(np.abs(result) ** 2)
        self.assertAlmostEqual(measured_power_ratio, 10 ** (-1.0 / 10.0), places=10)

    def test_wdm_batch_shape(self) -> None:
        fields = np.ones((4, 512), dtype=np.complex128)
        result = propagate_wdm_channels(
            fields,
            sample_rate_hz=200e9,
            length_m=500.0,
            attenuation_db_km=0.5,
            dispersion_ps_nm_km=0.0,
            wavelengths_nm=(1271.0, 1291.0, 1311.0, 1331.0),
            nonlinear_enabled=False,
            gamma_w_inv_km=1.3,
            ssfm_steps=4,
        )
        self.assertEqual(result.shape, fields.shape)

    def test_memoryless_mlse(self) -> None:
        samples = np.array([-3.1, -0.8, 1.2, 2.9])
        detected = mlse_detect(samples, np.array([1.0]))
        np.testing.assert_array_equal(detected, np.array([-3.0, -1.0, 1.0, 3.0]))

    def test_touchstone_s21_db_import_and_gain(self) -> None:
        with TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.s2p"
            path.write_text(
                "# GHZ S DB R 50\n"
                "0 0 0 -6 0 -80 0 0 0\n"
                "20 0 0 -6 0 -80 0 0 0\n",
                encoding="utf-8",
            )
            config = MeasuredS21Config(enabled=True, path=str(path))
            response = load_measured_s21(config)
            self.assertAlmostEqual(abs(response.s21[0]), 10 ** (-6 / 20))
            signal = np.ones(1024, dtype=np.float64)
            filtered, metadata = apply_measured_s21(signal, 40e9, config)
            self.assertAlmostEqual(float(np.mean(filtered)), 10 ** (-6 / 20), places=6)
            self.assertEqual(metadata["source_format"], "touchstone")


if __name__ == "__main__":
    unittest.main()
