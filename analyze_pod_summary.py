#!/usr/bin/env python3
import argparse
import glob
import math
import os
import re
from statistics import mean

KV_RE = re.compile(r"(\w+)=([^\s]+)")


def parse_kv_pairs(line: str) -> dict:
    out = {}
    for k, v in KV_RE.findall(line):
        out[k] = v
    return out


def to_float(v: str, default: float = 0.0) -> float:
    try:
        return float(v)
    except Exception:
        return default


def parse_int(v: str, default: int = 0) -> int:
    try:
        return int(float(v))
    except Exception:
        return default


def parse_list_segment(line: str, key: str):
    m = re.search(rf"{key}=\(([^)]*)\)", line)
    if not m:
        return []
    raw = m.group(1).strip()
    if not raw:
        return []
    return [x.strip() for x in raw.split(",") if x.strip()]


def balance_metrics(counts):
    if not counts:
        return {"total": 0, "nodes": 0, "max_min_gap": 0, "stddev": 0.0, "cv": 0.0}
    total = sum(counts)
    n = len(counts)
    avg = total / n if n else 0
    var = sum((c - avg) ** 2 for c in counts) / n if n else 0
    stddev = math.sqrt(var)
    cv = (stddev / avg) if avg > 0 else 0.0
    return {
        "total": total,
        "nodes": n,
        "max_min_gap": max(counts) - min(counts),
        "stddev": stddev,
        "cv": cv,
    }


def analyze_file(path: str):
    resource_rows = []
    placement_rows = []

    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if "ResourceUsage run=" in line:
                kv = parse_kv_pairs(line)
                resource_rows.append(
                    {
                        "run": parse_int(kv.get("run", "0")),
                        "runningPods": parse_int(kv.get("runningPods", "0")),
                        "cpu_total_m": to_float(kv.get("cpu_total_m", "0")),
                        "mem_total_mi": to_float(kv.get("mem_total_mi", "0")),
                        "net_rx": to_float(kv.get("net_rx_bytes_total", "0")),
                        "net_tx": to_float(kv.get("net_tx_bytes_total", "0")),
                        "net_status": kv.get("net_status", "unknown"),
                    }
                )
            elif "PodPlacement run=" in line:
                kv = parse_kv_pairs(line)
                counts = [parse_int(x, 0) for x in parse_list_segment(line, "counts")]
                nodes = parse_list_segment(line, "nodes")
                bm = balance_metrics(counts)
                placement_rows.append(
                    {
                        "run": parse_int(kv.get("run", "0")),
                        "nodes": nodes,
                        "counts": counts,
                        **bm,
                    }
                )

    return resource_rows, placement_rows


def print_summary(path: str, resources, placements):
    print(f"\n=== {path} ===")

    if resources:
        cpu_vals = [r["cpu_total_m"] for r in resources]
        mem_vals = [r["mem_total_mi"] for r in resources]
        pods_vals = [r["runningPods"] for r in resources]
        net_ok = sum(1 for r in resources if r["net_status"] == "ok")
        print("ResourceUsage:")
        print(f"  samples={len(resources)}")
        print(f"  runningPods: avg={mean(pods_vals):.2f} min={min(pods_vals)} max={max(pods_vals)}")
        print(f"  cpu_total_m: avg={mean(cpu_vals):.2f} min={min(cpu_vals):.2f} max={max(cpu_vals):.2f}")
        print(f"  mem_total_mi: avg={mean(mem_vals):.2f} min={min(mem_vals):.2f} max={max(mem_vals):.2f}")
        print(f"  net_status_ok={net_ok}/{len(resources)}")
    else:
        print("ResourceUsage: no rows found")

    if placements:
        gaps = [p["max_min_gap"] for p in placements]
        cvs = [p["cv"] for p in placements]
        totals = [p["total"] for p in placements]
        print("PodPlacement:")
        print(f"  samples={len(placements)}")
        print(f"  scheduled_pods_total: avg={mean(totals):.2f} min={min(totals)} max={max(totals)}")
        print(f"  max_min_gap: avg={mean(gaps):.2f} min={min(gaps)} max={max(gaps)}")
        print(f"  coefficient_of_variation: avg={mean(cvs):.4f} min={min(cvs):.4f} max={max(cvs):.4f}")
    else:
        print("PodPlacement: no rows found")


def main():
    parser = argparse.ArgumentParser(
        description="Analyze pod-summary logs for ResourceUsage and PodPlacement patterns."
    )
    parser.add_argument(
        "patterns",
        nargs="*",
        default=["~/experiment/swm-benchmark/exp1/pod-summary_19May_*.log"],
        help="Glob pattern(s) for pod summary logs",
    )
    args = parser.parse_args()

    files = []
    for p in args.patterns:
        files.extend(glob.glob(os.path.expanduser(p)))
    files = sorted(set(files))

    if not files:
        print("No files matched.")
        return 1

    all_resources = []
    all_placements = []

    for path in files:
        res, plc = analyze_file(path)
        print_summary(path, res, plc)
        all_resources.extend(res)
        all_placements.extend(plc)

    if len(files) > 1:
        print("\n=== OVERALL ===")
        print_summary("all files", all_resources, all_placements)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
