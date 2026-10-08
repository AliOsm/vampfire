"""Summarize repetitions, preserving failures and the sample count of every metric."""
import argparse
import csv
import json
from pathlib import Path
import shutil
from statistics import median


APPS = ("rust", "vampfire")
ROUTES = (
    "room_show", "messages_page", "sidebar", "search", "avatar", "static_css",
    "up", "post_message",
)
HTTP_FIELDS = (
    "rps", "p50_ms", "p90_ms", "p99_ms", "server_cpu_percent",
    "client_cpu_percent", "host_unaccounted_cpu_percent", "server_cpu_us_per_op", "peak_rss_mib", "avg_bytes",
)


def distribution(values):
    values = [value for value in values if value is not None]
    return {
        "n": len(values),
        "median": median(values) if values else None,
        "min": min(values) if values else None,
        "max": max(values) if values else None,
    }


def http_value(row, field):
    if field in ("rps", "avg_bytes"):
        return row[field]
    if field in ("p50_ms", "p90_ms", "p99_ms"):
        return row["latency"].get(field)
    resources = row["resources"]
    if field == "peak_rss_mib":
        return resources["server_sampled_peak_rss_bytes"] / 1024**2
    if field == "server_cpu_us_per_op":
        return resources["server_cpu_seconds"] * 1e6 / row["ok"] if row["ok"] else None
    return resources.get(field.replace("_percent", "_percent_one_core"))


def connected_rss(directory, count):
    phases_path = directory / f"cable-{count}.stderr"
    samples_path = directory / "memory-samples.json"
    if not phases_path.exists() or not samples_path.exists():
        return None
    phases = {}
    for line in phases_path.read_text().splitlines():
        parts = line.split()
        if parts[:1] == ["PHASE"]:
            phases[parts[1]] = int(parts[2])
    if not {"connected", "paced"} <= phases.keys():
        return None
    samples = json.loads(samples_path.read_text())
    values = [s["rss_bytes"] / 1024**2 for s in samples
              if phases["connected"] <= s["unix_ms"] < phases["paced"]]
    return median(values) if values else None


def upload_summary(runs, key, expected_reps, uploads_per_rep):
    recorded = [r[key] for r in runs if key in r]
    uploads = [upload for row in recorded for upload in row["runs"]]
    return {
        "expected_repetitions": expected_reps,
        "recorded_repetitions": len(recorded),
        "expected_uploads": expected_reps * uploads_per_rep,
        "recorded_uploads": len(uploads),
        "recorded_successes": sum(r.get("thumb_status") == 200 for r in uploads),
        "decoded_thumbnails": sum(r.get("pixels_decoded", False) for r in uploads),
        "median_total_ms": distribution(r["median_total_ms"] for r in recorded),
        "thumbnail_bytes": sorted({r["thumb_bytes"] for r in uploads if "thumb_bytes" in r}),
    }


def fanout_errors(row):
    return row.get("post_errors", row["latency"].get("post_errors", 0) + row["throughput"].get("post_errors", 0))


def summarize(root):
    environment = json.loads((root / "environment.json").read_text())
    if environment.get("smoke"):
        raise ValueError("Use full runs for the comparison report, not smoke results.")
    conditions = environment["conditions"]
    repetitions = conditions["repetitions"]
    concurrencies = conditions["http_concurrency"]
    client_counts = conditions["cable_clients"]
    results = {}
    summary = {"http": [], "mixed": [], "cable": [], "process": {}, "upload": {}, "checks": {}}
    for name in APPS:
        runs = []
        missing = []
        for rep in range(1, repetitions + 1):
            path = root / f"{name}-{rep}" / "result.json"
            if path.exists():
                runs.append(json.loads(path.read_text()))
            else:
                missing.append(rep)
        results[name] = runs
        all_http = [h for run in runs for h in run["http"]]
        all_cable = [c for run in runs for c in run["cable"]]
        all_mixed = [h for run in runs for h in run.get("mixed", [])]
        summary["checks"][name] = {
            "expected_repetitions": repetitions,
            "recorded_repetitions": len(runs),
            "missing_repetitions": missing,
            "run_errors": [{"rep": r["rep"], "error": r["error"]} for r in runs if "error" in r],
            "expected_http_scenarios": repetitions * len(ROUTES) * len(concurrencies),
            "recorded_http_scenarios": len(all_http),
            "http_logical_operations": sum(h["ok"] for h in all_http),
            "http_errors": sum(h["errors"] + sum(n for status, n in h["statuses"].items()
                               if int(status) >= 400) for h in all_http),
            "http_invalid_responses": sum(h.get("invalid_responses", 0) for h in all_http),
            "mixed_scenarios": len(all_mixed),
            "mixed_invalid_responses": sum(h.get("invalid_responses", 0) + h["writer"].get("invalid_responses", 0) for h in all_mixed),
            "mixed_errors": sum(h["errors"] + h["writer"]["errors"] for h in all_mixed),
            "verified_acknowledged_writes": sum(a["acknowledged"] for r in runs for a in r.get("acknowledged_writes", []) if a["verified"]),
            "expected_fanout_scenarios": repetitions * len(client_counts),
            "recorded_fanout_scenarios": len(all_cable),
            "fanout_unready_clients": sum(c["clients"] - c["ready"] for c in all_cable),
            "fanout_failed_clients": sum(c["failed"] for c in all_cable),
            "fanout_post_errors": sum(fanout_errors(c) for c in all_cable),
            "fanout_incomplete_messages": sum(
                c["throughput"]["posted"] - c["throughput"]["complete"]
                + c["latency"]["messages"] - c["latency"]["complete"] for c in all_cable),
            "fanout_complete_messages": sum(c["throughput"]["complete"] + c["latency"]["complete"]
                                            for c in all_cable),
            "fanout_complete_client_deliveries": sum(
                c["ready"] * (c["throughput"]["complete"] + c["latency"]["complete"])
                for c in all_cable),
        }
        for route in ROUTES:
            for concurrency in concurrencies:
                rows = [h for h in all_http if h["route"] == route and h["conc"] == concurrency]
                row = {"app": name, "route": route, "concurrency": concurrency}
                for field in HTTP_FIELDS:
                    values = [http_value(h, field) for h in rows]
                    row[field] = distribution(v for v in values if v is not None)
                summary["http"].append(row)
        for route in ("messages_page", "sidebar", "search"):
            rows = [h for h in all_mixed if h["route"] == route]
            row = {"app": name, "route": route, "concurrency": 16}
            for field in HTTP_FIELDS:
                row[field] = distribution(http_value(h, field) for h in rows)
            summary["mixed"].append(row)
        for count in client_counts:
            rows = [c for c in all_cable if c["clients"] == count]
            row = {
                "app": name, "clients": count, "recorded_repetitions": len(rows),
                "successful_repetitions": sum(
                    c["ready"] == count and c["failed"] == 0 and fanout_errors(c) == 0
                    and c["latency"]["messages"] == c["latency"]["complete"]
                    and c["throughput"]["posted"] == c["throughput"]["complete"] for c in rows),
            }
            for field in ("delivered_msgs_per_sec", "frames_per_sec"):
                row[field] = distribution(c["throughput"][field] for c in rows)
            for field in ("p50_ms", "p90_ms", "p99_ms"):
                row["all_clients_" + field] = distribution(c["latency"]["all_clients"].get(field) for c in rows)
                row["per_client_" + field] = distribution(c["latency"]["per_client"].get(field) for c in rows)
            row["server_peak_rss_mib"] = distribution(
                c["resources"]["server_sampled_peak_rss_bytes"] / 1024**2 for c in rows)
            for field in ("client_cpu_percent", "server_cpu_percent", "host_unaccounted_cpu_percent"):
                row[field] = distribution(c["resources"].get(field + "_one_core") for c in rows)
            idle = [connected_rss(root / f"{name}-{r['rep']}", count) for r in runs]
            row["connected_rss_mib"] = distribution(v for v in idle if v is not None)
            summary["cable"].append(row)
        summary["process"][name] = {
            "cold_start_ms": distribution(r["cold_start_ms"] for r in runs),
            "idle_rss_mib": distribution(r["idle"]["rss_bytes"] / 1024**2 for r in runs if "idle" in r),
            "peak_rss_mib": distribution(r["peak_sampled_rss_bytes"] / 1024**2
                                         for r in runs if "peak_sampled_rss_bytes" in r),
            "http_peak_rss_mib": distribution(
                max(x["resources"]["server_sampled_peak_rss_bytes"] for x in r["http"]) / 1024**2
                for r in runs if r["http"]),
            "http_cable_peak_rss_mib": distribution(
                max(x["resources"]["server_sampled_peak_rss_bytes"] for x in r["http"] + r["cable"]) / 1024**2
                for r in runs if r["http"] or r["cable"]),
            "peak_wal_mib": distribution(r["peak_wal_bytes"] / 1024**2 for r in runs if "peak_wal_bytes" in r),
            "pending_jobs_at_end": distribution(sum(j["count"] for j in r["pending_jobs_by_attempt"])
                                                for r in runs if "pending_jobs_by_attempt" in r),
        }
        summary["upload"][name] = {
            "actual_thumbnail": upload_summary(runs, "upload_actual_thumbnail" if name == "rust" else "upload",
                                                repetitions, conditions["upload_repetitions"]),
        }
        if name == "rust":
            summary["upload"][name]["upstream_first_image"] = upload_summary(
                runs, "upload", repetitions, conditions["upload_repetitions"])
    return summary, results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--export", type=Path)
    args = parser.parse_args()
    summary, results = summarize(args.directory)
    (args.directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    with (args.directory / "http-summary.csv").open("w", newline="") as stream:
        writer = csv.writer(stream)
        stats = ("n", "median", "min", "max")
        writer.writerow(["app", "route", "concurrency", *[f"{f}_{s}" for f in HTTP_FIELDS for s in stats]])
        for row in summary["http"]:
            writer.writerow([row["app"], row["route"], row["concurrency"],
                             *[row[f][s] for f in HTTP_FIELDS for s in stats]])
    if args.export:
        args.export.mkdir(parents=True, exist_ok=False)
        for filename in ("environment.json", "summary.json", "http-summary.csv"):
            shutil.copy2(args.directory / filename, args.export / filename)
        for name, runs in results.items():
            for run in runs:
                label = f"{name}-{run['rep']}"
                (args.export / f"{label}.json").write_text(json.dumps(run, indent=2) + "\n")
                # Keep connected-idle memory independently verifiable.
                for filename in ("memory-samples.json", "cable-100.stderr", "cable-500.stderr",
                                 "cable-1000.stderr", "server.resources.json"):
                    source = args.directory / label / filename
                    if source.exists():
                        shutil.copy2(source, args.export / f"{label}-{filename}")
    print(json.dumps({"directory": str(args.directory), "checks": summary["checks"],
                      "upload": summary["upload"]}, indent=2))


if __name__ == "__main__":
    main()
