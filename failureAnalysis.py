#!/usr/bin/env python3
"""
Analyze PodFailureSummary lines in pod-summary logs and create failure plots.

It also counts recent WarningEvents containing "exhausted solver retries".
Only events whose LAST SEEN age is within --solver-retry-window-seconds are counted.
"""

from __future__ import annotations

import argparse
import gc
import math
import re
from pathlib import Path
from typing import List, Tuple

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd


FILE_POD_RE = re.compile(r"_(?P<pod_count>\d+)\.log$")
SCHEDULER_SUFFIX_RE = re.compile(r"_(?P<scheduler>qos(?:-assured)?|default|def)-scheduler_", flags=re.IGNORECASE)
SCHEDULER_HEADER_RE = re.compile(r"^#\s*scheduler:\s*(?P<scheduler>[^\n]+)\s*$", flags=re.MULTILINE)
POD_FAILURE_RE = re.compile(
    r"PodFailureSummary\s+"
    r"run=(?P<run_id>\d+)\s+"
    r"jobIterations=(?P<job_iterations>\d+)\s+"
    r"qps=(?P<qps>\d+)\s+"
    r"burst=(?P<burst>\d+)\s+"
    r"bookinfo_replicas=(?P<bookinfo_replicas>\d+)\s+"
    r"restarts=(?P<restarts>\d+)\s+"
    r"waitingFailures=(?P<waiting_failures>\d+)\s+"
    r"terminated=(?P<terminated>\d+)\s+"
    r"warningEvents=(?P<warning_events>\d+)"
)
WARNING_EVENTS_RE = re.compile(
    r"WarningEvents\s+run=(?P<run_id>\d+)\s+"
    r"jobIterations=(?P<job_iterations>\d+)\s+"
    r"qps=(?P<qps>\d+)\s+"
    r"burst=(?P<burst>\d+)\s+"
    r"bookinfo_replicas=(?P<bookinfo_replicas>\d+)"
)
METRIC_START_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\s+run=|\s*$)")
SOLVER_RETRIES_RE = re.compile(r"exhausted solver retries:\s*(?P<retries>\d+)\s*/\s*(?P<limit>\d+)", re.IGNORECASE)


SYSTEM_ORDER = {"def": 0, "qos": 1, "qos_assured": 2}
SYSTEM_LABELS = {"def": "Default", "qos": "QoS", "qos_assured": "QoS-ASSURED"}
SYSTEM_COLORS = {"def": "blue", "qos": "green", "qos_assured": "orange"}


def _norm_sched_name(value: object) -> str:
    text = str(value).strip().lower()
    if "assured" in text:
        return "qos_assured"
    if "qos" in text:
        return "qos"
    if "default" in text or text == "def":
        return "def"
    return text


def _display_system(system: str) -> str:
    return SYSTEM_LABELS.get(system, system)


def _system_color(system: str) -> str:
    return SYSTEM_COLORS.get(system, "gray")


def _ordered_systems(df: pd.DataFrame) -> List[str]:
    systems = [str(x) for x in df["system"].dropna().unique().tolist()]
    return sorted(systems, key=lambda s: (SYSTEM_ORDER.get(s, 99), s))


def scheduler_to_system(scheduler: str, filename: str) -> str:
    text = f"{scheduler} {filename}".lower()
    if "assured" in text:
        return "qos_assured"
    if "qos" in text:
        return "qos"
    if "default" in text or "def" in text:
        return "def"
    return "unknown"


def scheduler_from_log(text: str, filename: str) -> str:
    header = SCHEDULER_HEADER_RE.search(text)
    if header:
        return header.group("scheduler").strip()
    suffix = SCHEDULER_SUFFIX_RE.search(filename)
    if suffix:
        sched = suffix.group("scheduler").lower()
        return "default-scheduler" if sched in {"default", "def"} else f"{sched}-scheduler"
    return "unknown"


def pod_count_from_filename(filename: str) -> int | None:
    match = FILE_POD_RE.search(filename)
    return int(match.group("pod_count")) if match else None


def duration_to_seconds(value: str) -> float | None:
    token = value.strip().split()[0]
    if not token or token.upper() in {"LAST", "LASTSEEN"}:
        return None
    total = 0.0
    matches = list(re.finditer(r"(\d+(?:\.\d+)?)(ms|d|h|m|s)", token))
    if not matches:
        return None
    for match in matches:
        number = float(match.group(1))
        unit = match.group(2)
        if unit == "d":
            total += number * 86400
        elif unit == "h":
            total += number * 3600
        elif unit == "m":
            total += number * 60
        elif unit == "s":
            total += number
        elif unit == "ms":
            total += number / 1000
    return total


def recent_solver_retry_stats(lines: List[str], start_index: int, window_seconds: int) -> tuple[int, int, float]:
    count = 0
    total_retries = 0
    index = start_index + 1
    if index < len(lines) and WARNING_EVENTS_RE.search(lines[index]):
        index += 1

    while index < len(lines):
        line = lines[index].rstrip("\n")
        stripped = line.strip()
        if not stripped:
            index += 1
            continue
        if stripped.startswith("=") or POD_FAILURE_RE.search(stripped):
            break
        if METRIC_START_RE.match(stripped) and not stripped.startswith(("LAST SEEN", "LAST", "No resources")):
            break

        retry_match = SOLVER_RETRIES_RE.search(stripped)
        if retry_match:
            seconds = duration_to_seconds(stripped)
            if seconds is not None and seconds <= window_seconds:
                count += 1
                total_retries += int(retry_match.group("retries"))
        index += 1

    avg_retries = total_retries / count if count else 0.0
    return count, total_retries, avg_retries


def parse_summary_log(path: Path, solver_retry_window_seconds: int) -> pd.DataFrame:
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()
    scheduler = scheduler_from_log(text, path.name)
    system = scheduler_to_system(scheduler, path.name)
    pod_count = pod_count_from_filename(path.name)
    rows = []

    for index, line in enumerate(lines):
        match = POD_FAILURE_RE.search(line)
        if not match:
            continue
        solver_retry_events, solver_retry_total, solver_retry_avg = recent_solver_retry_stats(
            lines, index, solver_retry_window_seconds
        )
        rows.append(
            {
                "input_log": path.name,
                "scheduler": scheduler,
                "system": system,
                "pod_count": pod_count,
                "run_id": int(match.group("run_id")),
                "qps": int(match.group("qps")),
                "restarts": int(match.group("restarts")),
                "waitingFailures": int(match.group("waiting_failures")),
                "terminated": int(match.group("terminated")),
                "warningEvents": int(match.group("warning_events")),
                "exhaustedSolverRetriesRecent": solver_retry_events,
                "exhaustedSolverRetryTotalRecent": solver_retry_total,
                "exhaustedSolverRetryAvgRecent": solver_retry_avg,
            }
        )

    return pd.DataFrame(rows)


def parse_logs(base_dir: Path, glob_pattern: str, solver_retry_window_seconds: int) -> pd.DataFrame:
    paths = sorted(base_dir.glob(glob_pattern))
    if not paths:
        raise SystemExit(f"ERROR: no logs matched '{glob_pattern}' under {base_dir}")
    parts = [parse_summary_log(path, solver_retry_window_seconds) for path in paths]
    parts = [part for part in parts if not part.empty]
    if not parts:
        return pd.DataFrame(
            columns=[
                "input_log",
                "scheduler",
                "system",
                "pod_count",
                "run_id",
                "qps",
                "restarts",
                "waitingFailures",
                "terminated",
                "warningEvents",
                "exhaustedSolverRetriesRecent",
                "exhaustedSolverRetryTotalRecent",
                "exhaustedSolverRetryAvgRecent",
            ]
        )
    return pd.concat(parts, ignore_index=True).sort_values(["pod_count", "qps", "system"], kind="stable")


def summarize_failures(raw_df: pd.DataFrame) -> pd.DataFrame:
    metric_cols = [
        "restarts",
        "waitingFailures",
        "terminated",
        "warningEvents",
        "exhaustedSolverRetriesRecent",
        "exhaustedSolverRetryTotalRecent",
    ]
    mean_cols = ["exhaustedSolverRetryAvgRecent"]
    if raw_df.empty:
        return pd.DataFrame(columns=["system", "pod_count", "qps", *metric_cols, *mean_cols])
    grouped_sum = raw_df.groupby(["system", "pod_count", "qps"], as_index=False)[metric_cols].sum(numeric_only=True)
    grouped_mean = raw_df.groupby(["system", "pod_count", "qps"], as_index=False)[mean_cols].mean(numeric_only=True)
    grouped = grouped_sum.merge(grouped_mean, on=["system", "pod_count", "qps"], how="left")
    return grouped.sort_values(["pod_count", "qps", "system"], kind="stable").reset_index(drop=True)


def save_chart_with_outside_legend(fig, ax, out_path: Path, dpi: int) -> None:
    handles, _labels = ax.get_legend_handles_labels()
    if handles:
        ax.legend(loc="upper left", bbox_to_anchor=(1.02, 1.0), borderaxespad=0.0)
        fig.tight_layout(rect=(0, 0, 0.82, 1))
    else:
        fig.tight_layout()
    fig.savefig(out_path, dpi=dpi)


def plot_failure_bars(
    summary: pd.DataFrame,
    out_dir: Path,
    pod_counts: Tuple[int, ...],
    qps_values: Tuple[int, ...],
    dpi: int,
) -> List[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    systems = _ordered_systems(summary)
    metric_map = {
        "restarts": ("Container restarts", "count"),
        "waitingFailures": ("Waiting failure states", "count"),
        "terminated": ("Terminated containers", "count"),
        "warningEvents": ("Warning events", "count"),
        "exhaustedSolverRetriesRecent": ("Recent exhausted solver retry events", "count"),
        "exhaustedSolverRetryTotalRecent": ("Recent exhausted solver retries total", "retries"),
        "exhaustedSolverRetryAvgRecent": ("Recent exhausted solver retries average", "avg retries"),
    }
    created: List[Path] = []

    for qps in qps_values:
        for metric_name, (label, ylabel) in metric_map.items():
            fig, ax = plt.subplots(figsize=(8.2, 4.8))
            x = np.arange(len(pod_counts), dtype=float)
            nsys = max(len(systems), 1)
            group_width = 0.8
            width = group_width / nsys
            start = -group_width / 2 + width / 2

            for idx, system in enumerate(systems):
                values = []
                for pods in pod_counts:
                    selected = summary.loc[
                        (summary["system"] == system)
                        & (summary["qps"] == qps)
                        & (summary["pod_count"] == pods),
                        metric_name,
                    ]
                    values.append(float(selected.iloc[0]) if len(selected) and pd.notna(selected.iloc[0]) else 0.0)
                ax.bar(
                    x + start + idx * width,
                    values,
                    width=width,
                    color=_system_color(system),
                    label=_display_system(system),
                )

            ax.set_xticks(x)
            ax.set_xticklabels([str(p) for p in pod_counts])
            ax.set_xlabel("number of pods")
            ax.set_ylabel(ylabel)
            ax.set_title(f"QPS {qps} - {label}")
            ax.grid(True, axis="y", linestyle="--", linewidth=0.6, alpha=0.5)

            out_path = out_dir / f"failure_{metric_name}_qps{qps}.png"
            save_chart_with_outside_legend(fig, ax, out_path, dpi)
            plt.close(fig)
            created.append(out_path)
            gc.collect()

    return created


def merge_metric_qps_plots(
    created_paths: List[Path],
    out_dir: Path,
    dpi: int,
    max_panels_per_figure: int,
) -> List[Path]:
    rx = re.compile(r"^failure_(?P<metric>.+)_qps(?P<qps>\d+)\.png$")
    grouped: dict[str, list[tuple[int, Path]]] = {}
    for path in created_paths:
        match = rx.match(path.name)
        if match:
            grouped.setdefault(match.group("metric"), []).append((int(match.group("qps")), path))

    merged: List[Path] = []
    for metric, items in grouped.items():
        items = sorted(items, key=lambda item: item[0])
        for page, offset in enumerate(range(0, len(items), max_panels_per_figure)):
            page_items = items[offset : offset + max_panels_per_figure]
            panel_count = len(page_items)
            ncols = 2
            nrows = int(math.ceil(panel_count / ncols))
            fig, axes = plt.subplots(nrows, ncols, figsize=(12, 4.8 * nrows))
            axes_arr = np.array(axes, dtype=object).reshape(-1)

            for idx, (qps, path) in enumerate(page_items):
                image = plt.imread(path)
                ax = axes_arr[idx]
                ax.imshow(image)
                ax.axis("off")
                ax.text(0.5, -0.06, f"QPS {qps}", transform=ax.transAxes, ha="center", va="top", fontsize=11)

            for idx in range(panel_count, len(axes_arr)):
                axes_arr[idx].axis("off")

            title = f"{metric} across QPS"
            if len(items) > max_panels_per_figure:
                title = f"{title} (part {page + 1})"
            fig.suptitle(title, fontsize=14, y=0.98)
            fig.subplots_adjust(left=0.02, right=0.98, bottom=0.08, top=0.92, wspace=0.03, hspace=0.20)

            suffix = f"_part{page + 1}" if len(items) > max_panels_per_figure else ""
            out_path = out_dir / f"panel_2x2_failure_{metric}{suffix}.png"
            fig.savefig(out_path, dpi=dpi)
            plt.close(fig)
            merged.append(out_path)
            gc.collect()

    return merged


def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze pod failure summaries and plot by pod count.")
    parser.add_argument(
        "--base-dir",
        default="/home/samizadeh/Downloads/swm-git/swm-benchmarking-paper-main/Experiment1/logs/",
        help="Directory containing pod-summary logs.",
    )
    parser.add_argument("--glob", default="*pod-summary_*.log", help="Glob pattern to select input logs.")
    parser.add_argument(
        "--plots-dir",
        default="plots_failure_analysis",
        help="Directory for failure-analysis PNG plots.",
    )
    parser.add_argument(
        "--solver-retry-window-seconds",
        type=int,
        default=240,
        help="Maximum LAST SEEN age for exhausted solver retries to count as recent.",
    )
    parser.add_argument("--pods", default="", help="Optional comma-separated pod counts.")
    parser.add_argument("--qps", default="", help="Optional comma-separated qps values.")
    parser.add_argument("--dpi", type=int, default=120, help="Output DPI.")
    parser.add_argument("--merge-max-panels", type=int, default=4, help="Maximum panels per merged figure.")
    parser.add_argument("--single-charts", action="store_true", help="Keep single charts in addition to panels.")
    args = parser.parse_args()

    base_dir = Path(args.base_dir).expanduser()
    if not base_dir.exists():
        raise SystemExit(f"ERROR: base dir does not exist: {base_dir}")

    raw_df = parse_logs(base_dir, args.glob, args.solver_retry_window_seconds)
    if raw_df.empty:
        raise SystemExit("ERROR: no PodFailureSummary lines found in input logs.")

    summary = summarize_failures(raw_df)
    print("[INFO] Failure summary:")
    print(summary.to_string(index=False))

    if args.pods.strip():
        pod_counts = tuple(int(value.strip()) for value in args.pods.split(",") if value.strip())
    else:
        pod_counts = tuple(sorted(int(value) for value in summary["pod_count"].dropna().unique()))

    if args.qps.strip():
        qps_values = tuple(int(value.strip()) for value in args.qps.split(",") if value.strip())
    else:
        qps_values = tuple(sorted(int(value) for value in summary["qps"].dropna().unique()))

    plots_dir = Path(args.plots_dir).expanduser()
    if not plots_dir.is_absolute():
        plots_dir = base_dir / plots_dir

    created = plot_failure_bars(summary, plots_dir, pod_counts, qps_values, args.dpi)
    print(f"[OK] {len(created)} failure plots written to: {plots_dir}")

    merged = merge_metric_qps_plots(created, plots_dir, args.dpi, args.merge_max_panels)
    print(f"[OK] {len(merged)} merged failure panels written to: {plots_dir}")

    if not args.single_charts:
        removed = 0
        for path in created:
            if path.exists():
                path.unlink()
                removed += 1
        print(f"[OK] Removed {removed} single failure plots (kept merged panels only).")


if __name__ == "__main__":
    main()
