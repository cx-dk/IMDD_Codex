"""Stable JSON and optional NumPy waveform outputs."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np

from .pipeline import SimulationResult


def write_json(data: dict[str, Any], path: str | Path) -> Path:
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as stream:
        json.dump(data, stream, indent=2, ensure_ascii=False, allow_nan=True)
        stream.write("\n")
    return output_path


def write_simulation_result(
    result: SimulationResult,
    directory: str | Path,
    save_waveforms: bool,
) -> tuple[Path, Path | None]:
    output_dir = Path(directory)
    json_path = write_json(result.to_dict(), output_dir / "simulation_result.json")
    waveform_path = None
    if save_waveforms:
        waveform_path = output_dir / "waveforms.npz"
        output_dir.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(waveform_path, **result.waveforms)
    return json_path, waveform_path

