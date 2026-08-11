"""Command-line interface."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from .config import load_config
from .monte_carlo import run_monte_carlo
from .pipeline import run_simulation
from .profiles import list_profiles
from .interfaces import list_electrical_interfaces
from .report import write_json, write_simulation_result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="imdd-sim")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("profiles", help="list available standard profiles")
    subparsers.add_parser("interfaces", help="list electrical interface standards")

    run = subparsers.add_parser("run", help="run one end-to-end simulation")
    run.add_argument("--config", required=True, type=Path)
    run.add_argument("--output", type=Path, help="override the configured output directory")

    monte = subparsers.add_parser("monte-carlo", help="run parallel Monte Carlo trials")
    monte.add_argument("--config", required=True, type=Path)
    monte.add_argument("--trials", type=int, default=8)
    monte.add_argument("--workers", type=int, default=2)
    monte.add_argument("--output", type=Path, help="output JSON path")
    return parser


def _print_profiles() -> None:
    rows = [profile.as_dict() for profile in list_profiles()]
    print(json.dumps(rows, indent=2, ensure_ascii=False))


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "profiles":
            _print_profiles()
            return 0
        if args.command == "interfaces":
            print(
                json.dumps(
                    [item.as_dict() for item in list_electrical_interfaces()],
                    indent=2,
                    ensure_ascii=False,
                )
            )
            return 0
        config = load_config(args.config)
        if args.command == "run":
            result = run_simulation(config)
            directory = args.output or Path(config.output.directory)
            json_path, waveform_path = write_simulation_result(
                result,
                directory,
                config.output.save_waveforms,
            )
            print(f"result: {json_path.resolve()}")
            if waveform_path is not None:
                print(f"waveforms: {waveform_path.resolve()}")
            print(
                "pre-FEC BER: "
                f"{result.metrics['pre_fec_ber']:.6g} "
                f"({result.metrics['bit_errors']}/{result.metrics['bits_compared']})"
            )
            return 0
        summary = run_monte_carlo(config, args.trials, args.workers)
        output_path = args.output or Path(config.output.directory) / "monte_carlo.json"
        write_json(summary, output_path)
        print(f"result: {output_path.resolve()}")
        print(f"pooled pre-FEC BER: {summary['pooled_pre_fec_ber']:.6g}")
        return 0
    except (KeyError, ValueError, RuntimeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
