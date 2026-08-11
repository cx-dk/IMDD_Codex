import unittest

import numpy as np

from imdd_sim.dsp.mlse import mlse_detect
from imdd_sim.models.fiber import propagate_fiber, propagate_wdm_channels
from imdd_sim.models.signal import (
    gray_demap_pam4,
    gray_map_pam4,
    pam4_decisions,
)


class SignalModelTests(unittest.TestCase):
    def test_gray_pam4_round_trip(self) -> None:
        bits = np.array([0, 0, 0, 1, 1, 1, 1, 0], dtype=np.uint8)
        symbols = gray_map_pam4(bits)
        recovered = gray_demap_pam4(pam4_decisions(symbols * 3.0))
        np.testing.assert_array_equal(recovered, bits)

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


if __name__ == "__main__":
    unittest.main()

