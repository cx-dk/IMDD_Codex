"""Versioned, immutable standard and engineering profiles."""

from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Mapping


@dataclass(frozen=True)
class StandardProfile:
    name: str
    family: str
    source: str
    status: str
    description: str
    values: Mapping[str, Any]
    limits: Mapping[str, Any]

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "family": self.family,
            "source": self.source,
            "status": self.status,
            "description": self.description,
            "values": deepcopy(dict(self.values)),
            "limits": deepcopy(dict(self.limits)),
        }


def _profile(
    *,
    name: str,
    family: str,
    source: str,
    status: str,
    description: str,
    values: dict[str, Any],
    limits: dict[str, Any],
) -> StandardProfile:
    return StandardProfile(
        name=name,
        family=family,
        source=source,
        status=status,
        description=description,
        values=MappingProxyType(values),
        limits=MappingProxyType(limits),
    )


_CWDM4 = (1271.0, 1291.0, 1311.0, 1331.0)

_PROFILES = {
    p.name: p
    for p in [
        _profile(
            name="ethernet_400gbase_dr4_100g_lane",
            family="ethernet",
            source="IEEE Std 802.3df-2024, Clause 124",
            status="normative",
            description="100G/lane PAM4 parallel-SMF DR, 500 m",
            values={
                "line_rate_gbps": 100.0,
                "symbol_rate_gbd": 53.125,
                "lane_count": 4,
                "reach_m": 500.0,
                "topology": "parallel",
                "wavelengths_nm": (1311.0,),
                "fiber_types": ("G.652.D", "G.657.A1", "G.657.A2"),
                "fec": "kp4",
            },
            limits={"pre_fec_ber_max": 2.4e-4, "tdecq_db_max": 3.4},
        ),
        _profile(
            name="ethernet_400gbase_fr4_100g_lane",
            family="ethernet",
            source="IEEE Std 802.3-2022, Clause 151",
            status="normative",
            description="100G/lane PAM4 four-wavelength CWDM FR, 2 km",
            values={
                "line_rate_gbps": 100.0,
                "symbol_rate_gbd": 53.125,
                "lane_count": 4,
                "reach_m": 2000.0,
                "topology": "cwdm4",
                "wavelengths_nm": _CWDM4,
                "fiber_types": ("G.652.D", "G.657.A1", "G.657.A2"),
                "fec": "kp4",
            },
            limits={
                "pre_fec_ber_max": 2.4e-4,
                "channel_loss_db_max": 4.0,
                "dispersion_ps_nm_min": -11.7,
                "dispersion_ps_nm_max": 6.6,
                "dgd_ps_max": 2.3,
                "tdecq_db_max": 3.4,
                "tecq_db_max": 3.4,
            },
        ),
        _profile(
            name="ethernet_200gbase_dr1_200g_lane_d2_0",
            family="ethernet",
            source="IEEE P802.3dj/D2.0, Clause 180",
            status="draft",
            description="200G/lane PAM4 parallel-SMF DR, 500 m",
            values={
                "line_rate_gbps": 200.0,
                "symbol_rate_gbd": 106.25,
                "lane_count": 1,
                "reach_m": 500.0,
                "topology": "parallel",
                "wavelengths_nm": (1311.0,),
                "fiber_types": ("G.652.D", "G.657.A1", "G.657.A2"),
                "fec": "outer_fec",
            },
            limits={
                "channel_loss_db_max": 3.5,
                "dispersion_ps_nm_min": -0.85,
                "dispersion_ps_nm_max": 0.65,
                "dgd_ps_max": 2.24,
                "tdecq_db_max": 3.4,
            },
        ),
        _profile(
            name="ethernet_800gbase_fr4_200g_lane_d2_0",
            family="ethernet",
            source="IEEE P802.3dj/D2.0, Clause 183",
            status="draft",
            description="200G/lane PAM4 four-wavelength CWDM FR, 2 km",
            values={
                "line_rate_gbps": 200.0,
                "symbol_rate_gbd": 113.4375,
                "lane_count": 4,
                "reach_m": 2000.0,
                "topology": "cwdm4",
                "wavelengths_nm": _CWDM4,
                "fiber_types": ("G.652.D", "G.657.A1", "G.657.A2"),
                "fec": "inner_fec",
            },
            limits={
                "channel_loss_db_max": 4.0,
                "dispersion_ps_nm_min": -11.26,
                "dispersion_ps_nm_max": 6.02,
                "dgd_ps_max": 2.3,
                "tdecq_db_max": 3.4,
            },
        ),
        _profile(
            name="pcie_6_4_64gt_optical",
            family="pcie",
            source="PCI Express Base Specification Revision 6.4",
            status="engineering",
            description="PCIe 6.x 64 GT/s PHY with transparent optical bridge",
            values={
                "line_rate_gbps": 64.0,
                "symbol_rate_gbd": 32.0,
                "lane_count": 1,
                "reach_m": 100.0,
                "topology": "parallel",
                "wavelengths_nm": (1311.0,),
                "fiber_types": ("G.652.D", "G.657.A1", "G.657.A2"),
                "fec": "pcie_lightweight",
            },
            limits={},
        ),
        _profile(
            name="pcie_7_0_128gt_optical",
            family="pcie",
            source="PCI Express Base Specification 7.0 Version 1.0",
            status="engineering",
            description="PCIe 7.0 128 GT/s PHY with transparent optical bridge",
            values={
                "line_rate_gbps": 128.0,
                "symbol_rate_gbd": 64.0,
                "lane_count": 1,
                "reach_m": 100.0,
                "topology": "parallel",
                "wavelengths_nm": (1311.0,),
                "fiber_types": ("G.652.D", "G.657.A1", "G.657.A2"),
                "fec": "pcie_lightweight",
            },
            limits={},
        ),
    ]
}


def get_profile(name: str) -> StandardProfile:
    try:
        return _PROFILES[name]
    except KeyError as exc:
        choices = ", ".join(sorted(_PROFILES))
        raise KeyError(f"unknown profile {name!r}; available: {choices}") from exc


def list_profiles() -> tuple[StandardProfile, ...]:
    return tuple(_PROFILES[name] for name in sorted(_PROFILES))

