from pathlib import Path
import unittest

from imdd_sim.config import PlatformConfig, load_config
from imdd_sim.profiles import get_profile, list_profiles
from imdd_sim.interfaces import select_electrical_interface


ROOT = Path(__file__).resolve().parents[1]


class ProfileConfigTests(unittest.TestCase):
    def test_required_profiles_are_registered(self) -> None:
        names = {profile.name for profile in list_profiles()}
        self.assertIn("ethernet_400gbase_fr4_100g_lane", names)
        self.assertIn("ethernet_800gbase_fr4_200g_lane_d2_0", names)
        self.assertIn("pcie_6_4_64gt_optical", names)
        self.assertIn("pcie_7_0_128gt_optical", names)

    def test_fr4_profile_has_cwdm_wavelengths(self) -> None:
        profile = get_profile("ethernet_400gbase_fr4_100g_lane")
        self.assertEqual(profile.values["wavelengths_nm"], (1271.0, 1291.0, 1311.0, 1331.0))
        self.assertEqual(profile.values["reach_m"], 2000.0)

    def test_example_configuration_loads(self) -> None:
        config = load_config(ROOT / "configs" / "ethernet_400gbase_fr4.toml")
        self.assertIsInstance(config, PlatformConfig)
        self.assertEqual(config.simulation.tx_sps, 4)
        self.assertEqual(config.receiver.processing_sps, 2.0)
        self.assertEqual(config.simulation.pattern_seed, 1)

    def test_measured_s21_path_is_resolved_from_config_directory(self) -> None:
        config = load_config(ROOT / "configs" / "ethernet_400gbase_fr4_measured_s21.toml")
        self.assertTrue(config.transmitter.measured_s21.enabled)
        self.assertTrue(Path(config.transmitter.measured_s21.path).is_file())

    def test_tx_sps_is_validated(self) -> None:
        config = PlatformConfig()
        config.simulation.tx_sps = 2
        with self.assertRaisesRegex(ValueError, "at least 4"):
            config.validate()

    def test_architecture_selects_distinct_interfaces(self) -> None:
        lpo = select_electrical_interface("lpo", 100.0, "ethernet")
        npo = select_electrical_interface("npo", 100.0, "ethernet")
        retimed = select_electrical_interface("retimed", 100.0, "ethernet")
        self.assertEqual(lpo.name, "oif_cei_112g_linear_pam4")
        self.assertEqual(npo.name, "oif_cei_112g_xsr_plus_pam4")
        self.assertEqual(retimed.name, "ieee_8023_annex_120g_c2m")


if __name__ == "__main__":
    unittest.main()
