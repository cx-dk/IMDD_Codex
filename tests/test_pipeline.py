from dataclasses import replace
from pathlib import Path
import unittest

from imdd_sim.config import load_config
from imdd_sim.monte_carlo import run_monte_carlo
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
        self.assertIn("tdecq_db", result.standard["checks"])
        self.assertEqual(result.standard["checks"]["tdecq_db"]["status"], "not_evaluated")

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


if __name__ == "__main__":
    unittest.main()
