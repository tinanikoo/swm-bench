#!/usr/bin/env python3

from __future__ import annotations

import argparse
import math
import re
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from statistics import median
from typing import Iterable


DEFAULT_LOG_DIR = Path(
    "/home/samizadeh/Downloads/swm-git/swm-benchmarking-paper-main/Experiment1/logs/ALL"
)
TARGET_METRICS = ("PodScheduledTime", "ContainerReadyTime")
FILENAME_RE = re.compile(
    r"pod-summary_(?P<date>\d{2}[A-Za-z]{3})_(?P<time>\d{4})_(?P<scheduler>.+)_(?P<count>\d+)\.log$"
)
KV_RE = re.compile(r"(\w+)=([^\s]+)")


@dataclass(frozen=True)
class MetricRecord:
    file_name: str
    path: Path
    started_at: datetime
    date_label: str
    scheduler: str
    qps: int
    metric: str
    expected_count: int
    actual_count: int
    observed_ms: int | None
    min_ms: int | None
    q1_ms: int | None
    median_ms: int | None
    q3_ms: int | None
    max_ms: int | None
    avg_ms: int | None
    samples: int | None
    header_qps: int | None
    file_expected_count: int | None
    file_scheduler: str | None


@dataclass(frozen=True)
class GroupKey:
    metric: str
    scheduler: str
    qps: int
    expected_count: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze pod-summary logs, build normal latency domains, and flag "
            "outliers or date-based shifts."
        )
    )
    parser.add_argument(
        "--log-dir",
        type=Path,
        default=DEFAULT_LOG_DIR,
        help=f"Directory containing pod-summary*.log files (default: {DEFAULT_LOG_DIR})",
    )
    parser.add_argument(
        "--show-all",
        action="store_true",
        help="Print all group summaries even if no anomalies are found.",
    )
    parser.add_argument(
        "--min-group-size",
        type=int,
        default=4,
        help="Minimum records needed before Tukey/IQR domains are used (default: 4).",
    )
    parser.add_argument(
        "--date-shift-ratio",
        type=float,
        default=0.30,
        help="Minimum daily-median change ratio to flag a date shift (default: 0.30).",
    )
    parser.add_argument(
        "--date-shift-ms",
        type=int,
        default=3000,
        help="Minimum daily-median absolute change in ms to flag a date shift (default: 3000).",
    )
    return parser.parse_args()


def parse_duration_to_ms(raw: str | None) -> int | None:
    if raw is None:
        return None
    match = re.fullmatch(r"(\d+)(ms|s)", raw.strip())
    if not match:
        return None
    value = int(match.group(1))
    unit = match.group(2)
    return value if unit == "ms" else value * 1000


def parse_int(raw: str | None) -> int | None:
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None


def parse_kv_pairs(line: str) -> dict[str, str]:
    return {key: value.rstrip(",") for key, value in KV_RE.findall(line)}


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise ValueError("percentile() requires at least one value")
    if len(values) == 1:
        return float(values[0])
    index = (len(values) - 1) * fraction
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return float(values[lower])
    weight = index - lower
    return float(values[lower] * (1 - weight) + values[upper] * weight)


def compute_domain(values: list[int], min_group_size: int) -> tuple[float, float]:
    ordered = sorted(values)
    if len(ordered) < min_group_size:
        return max(0.0, float(ordered[0])), float(ordered[-1])
    q1 = percentile(ordered, 0.25)
    q3 = percentile(ordered, 0.75)
    iqr = q3 - q1
    lower = q1 - (1.5 * iqr)
    upper = q3 + (1.5 * iqr)
    return max(0.0, lower), upper


def looks_noticeably_different(
    baseline_ms: float,
    candidate_ms: float,
    ratio_threshold: float,
    delta_threshold_ms: int,
) -> bool:
    if baseline_ms <= 0:
        return False
    ratio = abs(candidate_ms - baseline_ms) / baseline_ms
    delta = abs(candidate_ms - baseline_ms)
    return ratio >= ratio_threshold and delta >= delta_threshold_ms


def parse_log(path: Path) -> list[MetricRecord]:
    text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    header_scheduler: str | None = None
    header_qps: int | None = None
    started_at: datetime | None = None
    metric_lines: dict[str, dict[str, str]] = {}

    for line in text:
        stripped = line.strip()
        if stripped.startswith("# started:"):
            started_raw = stripped.split(":", 1)[1].strip()
            started_at = datetime.fromisoformat(started_raw)
        elif stripped.startswith("# scheduler:"):
            header_scheduler = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("# qps:"):
            qps_raw = stripped.split(":", 1)[1].strip().split()[0]
            header_qps = parse_int(qps_raw)
        elif any(stripped.startswith(metric) for metric in TARGET_METRICS):
            first_token = stripped.split()[0]
            metric_lines[first_token] = parse_kv_pairs(stripped)

    filename_match = FILENAME_RE.fullmatch(path.name)
    file_scheduler = filename_match.group("scheduler") if filename_match else None
    file_expected_count = (
        parse_int(filename_match.group("count")) if filename_match else None
    )
    file_date_label = filename_match.group("date") if filename_match else "unknown"

    if started_at is None:
        raise ValueError(f"Missing '# started:' header in {path}")

    records: list[MetricRecord] = []
    for metric in TARGET_METRICS:
        values = metric_lines.get(metric)
        if not values:
            continue

        if metric == "PodScheduledTime":
            expected_key = "expectedPods"
            actual_key = "scheduledPods"
        else:
            expected_key = "expectedContainers"
            actual_key = "readyContainers"

        qps = parse_int(values.get("qps")) or header_qps or 0
        records.append(
            MetricRecord(
                file_name=path.name,
                path=path,
                started_at=started_at,
                date_label=file_date_label,
                scheduler=header_scheduler or values.get("scheduler") or file_scheduler or "unknown",
                qps=qps,
                metric=metric,
                expected_count=parse_int(values.get(expected_key)) or file_expected_count or 0,
                actual_count=parse_int(values.get(actual_key)) or 0,
                observed_ms=parse_duration_to_ms(values.get("observed")),
                min_ms=parse_duration_to_ms(values.get("min")),
                q1_ms=parse_duration_to_ms(values.get("q1")),
                median_ms=parse_duration_to_ms(values.get("median")),
                q3_ms=parse_duration_to_ms(values.get("q3")),
                max_ms=parse_duration_to_ms(values.get("max")),
                avg_ms=parse_duration_to_ms(values.get("avg")),
                samples=parse_int(values.get("samples")),
                header_qps=header_qps,
                file_expected_count=file_expected_count,
                file_scheduler=file_scheduler,
            )
        )
    return records


def load_records(log_dir: Path) -> list[MetricRecord]:
    if not log_dir.exists():
        raise FileNotFoundError(f"Log directory does not exist: {log_dir}")

    records: list[MetricRecord] = []
    for path in sorted(log_dir.glob("pod-summary*.log")):
        try:
            records.extend(parse_log(path))
        except Exception as exc:
            print(f"SKIP {path.name}: {exc}")
    return records


def build_group_summary(
    key: GroupKey,
    records: list[MetricRecord],
    min_group_size: int,
    date_shift_ratio: float,
    date_shift_ms: int,
) -> tuple[list[str], list[str]]:
    summary_lines: list[str] = []
    anomaly_lines: list[str] = []

    avg_values = [record.avg_ms for record in records if record.avg_ms is not None]
    median_values = [record.median_ms for record in records if record.median_ms is not None]
    if not avg_values or not median_values:
        anomaly_lines.append(
            f"{key.metric} scheduler={key.scheduler} qps={key.qps} expected={key.expected_count}: missing avg/median values"
        )
        return summary_lines, anomaly_lines

    avg_domain = compute_domain(avg_values, min_group_size)
    median_domain = compute_domain(median_values, min_group_size)
    group_avg_median = float(median(avg_values))
    group_median_median = float(median(median_values))
    avg_alert_threshold_ms = max(2000.0, group_avg_median * 0.20)
    median_alert_threshold_ms = max(2000.0, group_median_median * 0.20)

    summary_lines.append(
        f"{key.metric} scheduler={key.scheduler} qps={key.qps} expected={key.expected_count} "
        f"files={len(records)} dates={len({record.started_at.date() for record in records})} "
        f"avg_domain=[{avg_domain[0]:.0f},{avg_domain[1]:.0f}]ms "
        f"median_domain=[{median_domain[0]:.0f},{median_domain[1]:.0f}]ms "
        f"baseline_avg={group_avg_median:.0f}ms"
    )

    for record in records:
        reasons: list[str] = []
        if record.actual_count < record.expected_count:
            reasons.append(
                f"incomplete={record.actual_count}/{record.expected_count}"
            )
        if record.header_qps is not None and record.header_qps != record.qps:
            reasons.append(f"qps-mismatch header={record.header_qps} row={record.qps}")
        if record.file_expected_count is not None and record.file_expected_count != record.expected_count:
            reasons.append(
                f"expected-mismatch file={record.file_expected_count} row={record.expected_count}"
            )
        if record.file_scheduler and record.file_scheduler != record.scheduler:
            reasons.append(
                f"scheduler-mismatch file={record.file_scheduler} header={record.scheduler}"
            )
        if (
            record.avg_ms is not None
            and (record.avg_ms < avg_domain[0] or record.avg_ms > avg_domain[1])
            and abs(record.avg_ms - group_avg_median) >= avg_alert_threshold_ms
        ):
            reasons.append(f"avg={record.avg_ms}ms outside [{avg_domain[0]:.0f},{avg_domain[1]:.0f}]ms")
        if (
            record.median_ms is not None
            and (record.median_ms < median_domain[0] or record.median_ms > median_domain[1])
            and abs(record.median_ms - group_median_median) >= median_alert_threshold_ms
        ):
            reasons.append(
                f"median={record.median_ms}ms outside [{median_domain[0]:.0f},{median_domain[1]:.0f}]ms"
            )

        if reasons:
            anomaly_lines.append(
                f"{record.started_at.date()} {record.file_name}: " + "; ".join(reasons)
            )

    daily_avg_values: dict[datetime.date, list[int]] = defaultdict(list)
    for record in records:
        if record.avg_ms is not None:
            daily_avg_values[record.started_at.date()].append(record.avg_ms)

    ordered_days = sorted(daily_avg_values.items())
    for index in range(1, len(ordered_days)):
        previous_day, previous_values = ordered_days[index - 1]
        current_day, current_values = ordered_days[index]
        previous_median = median(previous_values)
        current_median = median(current_values)
        if looks_noticeably_different(
            previous_median,
            current_median,
            ratio_threshold=date_shift_ratio,
            delta_threshold_ms=date_shift_ms,
        ):
            anomaly_lines.append(
                f"date-shift {current_day} vs {previous_day} for {key.metric} "
                f"scheduler={key.scheduler} qps={key.qps} expected={key.expected_count}: "
                f"daily_avg_median {previous_median}ms -> {current_median}ms"
            )

    return summary_lines, anomaly_lines


def analyze_records(
    records: Iterable[MetricRecord],
    show_all: bool,
    min_group_size: int,
    date_shift_ratio: float,
    date_shift_ms: int,
) -> list[str]:
    grouped: dict[GroupKey, list[MetricRecord]] = defaultdict(list)
    for record in records:
        grouped[
            GroupKey(
                metric=record.metric,
                scheduler=record.scheduler,
                qps=record.qps,
                expected_count=record.expected_count,
            )
        ].append(record)

    output: list[str] = []
    output.append(f"Analyzed {sum(len(items) for items in grouped.values())} metric rows across {len(grouped)} groups.")
    output.append("Domains use avg/median latency in ms. The `observed=` field is parsed but not used for alerts because it is too coarse in these logs.")
    output.append("")

    for key in sorted(
        grouped,
        key=lambda item: (item.metric, item.scheduler, item.qps, item.expected_count),
    ):
        records_for_group = sorted(grouped[key], key=lambda item: item.started_at)
        summary_lines, anomaly_lines = build_group_summary(
            key,
            records_for_group,
            min_group_size=min_group_size,
            date_shift_ratio=date_shift_ratio,
            date_shift_ms=date_shift_ms,
        )
        if show_all or anomaly_lines:
            output.extend(summary_lines)
            if anomaly_lines:
                output.extend(f"  ALERT {line}" for line in anomaly_lines)
            else:
                output.append("  OK no anomalies found")
            output.append("")

    if len(output) == 2:
        output.append("No groups produced output. Try --show-all.")
    return output


def main() -> int:
    args = parse_args()
    records = load_records(args.log_dir)
    if not records:
        print(f"No pod-summary*.log files found in {args.log_dir}")
        return 1

    report_lines = analyze_records(
        records,
        show_all=args.show_all,
        min_group_size=args.min_group_size,
        date_shift_ratio=args.date_shift_ratio,
        date_shift_ms=args.date_shift_ms,
    )
    print("\n".join(report_lines))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
