from dataclasses import replace
from pathlib import Path
import unittest

import numpy as np

from imdd_sim.config import load_config
from imdd_sim.monte_carlo import run_monte_carlo
from imdd_sim.models.signal import gray_map_pam4_codes
from imdd_sim.pipeline import run_simulation


ROOT = Path(__file__).resolve().parents[1]


class PipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        base = load_config(ROOT / "configs" / "ethernet_400gbase_fr4.toml")
        cls.config = replace(
            base,
            simulation=replace(base.simulation, symbols=2048, discard_symbols=64),
            dsp=replace(base.dsp, training_symbols=512),
        )

    def test_end_to_end_smoke(self) -> None:
        result = run_simulation(self.config)
        self.assertGreater(result.metrics["bits_compared"], 1000)
        self.assertLess(result.metrics["pre_fec_ber"], 0.05)
        self.assertEqual(result.metadata["wdm_channel_count"], 4)
        self.assertTrue(result.metadata["pattern_definition"]["standard_test_pattern"])
        self.assertIn("120.5.11.2.1", result.metadata["pattern_definition"]["reference"])
        self.assertIn("tdecq_db", result.standard["checks"])
        self.assertEqual(result.standard["checks"]["tdecq_db"]["status"], "not_evaluated")
        np.testing.assert_array_equal(
            gray_map_pam4_codes(result.waveforms["tx_bits"]),
            result.waveforms["tx_symbol_codes"],
        )

    def test_monte_carlo_serial(self) -> None:
        summary = run_monte_carlo(self.config, trials=2, workers=1)
        self.assertEqual(summary["trials"], 2)
        self.assertGreater(summary["total_bits"], 2000)

    def test_1p125_sps_timing_path(self) -> None:
        config = replace(
            self.config,
            receiver=replace(self.config.receiver, processing_sps=1.125),
        )
        result = run_simulation(config)
        self.assertLess(result.metrics["pre_fec_ber"], 0.01)

    def test_mm_tracks_adc_clock_offset(self) -> None:
        config = replace(
            self.config,
            receiver=replace(self.config.receiver, adc_clock_offset_ppm=100.0),
        )
        result = run_simulation(config)
        self.assertTrue(result.dsp["timing"]["locked"])
        self.assertGreater(result.dsp["timing"]["mean_omega_samples"], 2.0)

    def test_measured_s21_is_applied_and_reported(self) -> None:
        measured = load_config(
            ROOT / "configs" / "ethernet_400gbase_fr4_measured_s21.toml"
        )
        config = replace(
            measured,
            simulation=replace(measured.simulation, symbols=2048, discard_symbols=64),
            dsp=replace(measured.dsp, training_symbols=512),
        )
        result = run_simulation(config)
        response = result.metadata["measured_s21"]["transmitter"]
        self.assertTrue(response["enabled"])
        self.assertGreater(response["points"], 10)
        self.assertGreater(result.metrics["pre_fec_ber"], 0.0)

    def test_ssprq_transmit_receive_path(self) -> None:
        config = replace(
            self.config,
            simulation=replace(self.config.simulation, pattern="ssprq", pattern_seed=0),
        )
        result = run_simulation(config)
        prefix = "2222222222222132"
        actual = "".join(str(value) for value in result.waveforms["tx_symbol_codes"][:16])
        self.assertEqual(actual, prefix)
        self.assertEqual(result.metadata["pattern_definition"]["name"], "ssprq")
        self.assertLess(result.metrics["pre_fec_ber"], 0.05)


if __name__ == "__main__":
    unittest.main()
