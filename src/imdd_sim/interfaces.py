"""Electrical interface standards selected by architecture and lane generation."""

from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class ElectricalInterfaceProfile:
    name: str
    architecture: str
    generation_gbps: float
    source: str
    status: str
    reach_class: str
    c2m: bool

    def as_dict(self) -> dict[str, object]:
        return asdict(self)


_INTERFACES = {
    item.name: item
    for item in [
        ElectricalInterfaceProfile(
            "ieee_8023_annex_120g_c2m",
            "retimed",
            100.0,
            "IEEE 802.3 Annex 120G C2M",
            "normative",
            "c2m_vsr",
            True,
        ),
        ElectricalInterfaceProfile(
            "oif_cei_112g_linear_pam4",
            "lpo",
            100.0,
            "OIF CEI-112G-LINEAR-PAM4",
            "normative",
            "c2m_linear",
            True,
        ),
        ElectricalInterfaceProfile(
            "oif_cei_112g_xsr_plus_pam4",
            "npo",
            100.0,
            "OIF-CEI-05.3 CEI-112G-XSR+-PAM4",
            "normative",
            "d2oe_xsr_plus",
            False,
        ),
        ElectricalInterfaceProfile(
            "oif_eei_112g_rtlr",
            "lro",
            100.0,
            "OIF-EEI-112G-RTLR-01.0",
            "normative",
            "c2m_asymmetric",
            True,
        ),
        ElectricalInterfaceProfile(
            "ieee_p8023dj_d2_0_annex_176d_c2m",
            "retimed",
            200.0,
            "IEEE P802.3dj/D2.0 Annex 176D 800GAUI-4 C2M",
            "draft",
            "c2m_vsr",
            True,
        ),
        ElectricalInterfaceProfile(
            "oif_cei_224g_linear_provisional",
            "lpo",
            200.0,
            "OIF CEI-224G-Linear project baseline",
            "provisional",
            "c2m_linear",
            True,
        ),
        ElectricalInterfaceProfile(
            "oif_cei_224g_xsr_provisional",
            "npo",
            200.0,
            "OIF CEI-224G-XSR project baseline",
            "provisional",
            "d2oe_xsr",
            False,
        ),
        ElectricalInterfaceProfile(
            "oif_eei_224g_rtlr_provisional",
            "lro",
            200.0,
            "OIF EEI-224G-RTLR project baseline",
            "provisional",
            "c2m_asymmetric",
            True,
        ),
        ElectricalInterfaceProfile(
            "pcie_6_4_phy_64gt",
            "pcie_phy",
            64.0,
            "PCI Express Base Specification Revision 6.4",
            "normative",
            "electrical_phy",
            False,
        ),
        ElectricalInterfaceProfile(
            "pcie_7_0_phy_128gt",
            "pcie_phy",
            128.0,
            "PCI Express Base Specification 7.0 Version 1.0",
            "normative",
            "electrical_phy",
            False,
        ),
    ]
}


def get_electrical_interface(name: str) -> ElectricalInterfaceProfile:
    try:
        return _INTERFACES[name]
    except KeyError as exc:
        raise KeyError(f"unknown electrical interface {name!r}") from exc


def list_electrical_interfaces() -> tuple[ElectricalInterfaceProfile, ...]:
    return tuple(_INTERFACES[name] for name in sorted(_INTERFACES))


def select_electrical_interface(
    architecture: str,
    line_rate_gbps: float,
    family: str,
) -> ElectricalInterfaceProfile:
    if family == "pcie":
        name = "pcie_6_4_phy_64gt" if line_rate_gbps == 64.0 else "pcie_7_0_phy_128gt"
        return get_electrical_interface(name)
    matches = [
        item
        for item in _INTERFACES.values()
        if item.architecture == architecture and item.generation_gbps == line_rate_gbps
    ]
    if len(matches) != 1:
        raise ValueError(
            f"no unambiguous interface for architecture={architecture!r}, "
            f"line_rate_gbps={line_rate_gbps}"
        )
    return matches[0]

