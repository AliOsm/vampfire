"""Run isolated follow-ups after an incomplete reference suite; never pool them silently."""
import argparse
import hashlib
import os
from pathlib import Path
import signal
import sqlite3
import time

from run import App, LOADGEN, REFERENCE, lg, process_stats, validation, write


def measure(name, repetition, case, directory, count):
    directory.mkdir(parents=True)
    app = App(name, directory)
    report = {"app": name, "rep": repetition, "case": case, "fresh_seed": True,
              "cold_start_ms": app.cold_ms, "load_average_start": os.getloadavg()}
    try:
        time.sleep(10)
        report["idle"] = process_stats(app.pid)
        login = lg(app, "login", "--email", app.labels["emails.david"],
                   "--password", app.labels["passwords.all"])
        app.session = lg(app, "scrape", "--cookie", login["cookie"],
                         "--room", app.labels["rooms.watercooler"])
        app.session["cookie"] = login["cookie"]
        app.session["csrf"] = app.session["csrf"] or ""
        report["validation"] = validation(app)
        auth = ["--cookie", login["cookie"], "--csrf", app.session["csrf"]]
        if case == "cable":
            row = lg(app, "cable", *auth, "--room", app.labels["rooms.watercooler"],
                     "--streams", ",".join(app.session["streams"]), "--clients", count,
                     "--tput-secs", 15, "--posters", 4, "--latency-msgs", 30,
                     "--interval-ms", 200, file=f"cable-{count}")
            report["cable"] = row
            report["passed"] = (row["ready"] == count and row["failed"] == 0
                                and row["post_errors"] == 0
                                and row["latency"]["complete"] == row["latency"]["messages"]
                                and row["throughput"]["complete"] == row["throughput"]["posted"])
        elif case == "upload":
            args = ["--room", app.labels["rooms.hq"], "--file",
                    REFERENCE / "reference/test/fixtures/files/black_hole.jpg", "--reps", 5]
            if name == "rust":
                # Preserve the upstream series and its warming/order before correcting its selector.
                report["upload_upstream"] = lg(app, "upload", *auth, *args, file="upload-upstream")
                args += ["--actual-thumbnail", 1]
            report["upload"] = lg(app, "upload", *auth, *args, file="upload")
            report["passed"] = all(r.get("thumb_status") == 200 for r in report["upload"]["runs"])
    except Exception as error:
        report["error"] = str(error)
        report["passed"] = False
    finally:
        report["peak_sampled_rss_bytes"] = max((s["rss_bytes"] for s in app.samples), default=0)
        report["peak_wal_bytes"] = max((s["wal_bytes"] for s in app.samples), default=0)
        report["final"] = process_stats(app.pid)
        try:
            with sqlite3.connect(app.database, timeout=2) as db:
                report["final_message_count"] = db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
                if name == "vampfire":
                    report["pending_jobs_by_attempt"] = [
                        {"attempts": a, "count": n}
                        for a, n in db.execute("SELECT attempts,count(*) FROM jobs GROUP BY attempts")]
        except sqlite3.Error as error:
            report["final_database_error"] = str(error)
        app.close()
        write(directory / "result.json", report)
    print(f"{directory.name}: passed={report['passed']}; "
          f"error={report.get('error')}; "
          f"upload_ms={report.get('upload', {}).get('median_total_ms')}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=("cable", "upload"))
    parser.add_argument("--apps", nargs="+", choices=("rust", "vampfire"), default=["rust", "vampfire"])
    parser.add_argument("--clients", nargs="+", type=int, default=[500, 1000])
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    assert os.environ.get("VAMPFIRE_RESOURCE_GUARD"), "Use the resource guard."
    assert args.repetitions > 0 and all(0 < count <= 2000 for count in args.clients)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    args.out.mkdir(parents=True, exist_ok=False)
    write(args.out / "settings.json", {
        **vars(args), "out": str(args.out), "loadgen_sha256": hashlib.sha256(LOADGEN.read_bytes()).hexdigest(),
        "protocol_diagnostics": "Up to five WebSocket read errors/close frames are logged; app unchanged.",
        "scope": "Fresh isolated seed for each scenario; kept separate from the full-suite medians.",
    })
    for repetition in range(1, args.repetitions + 1):
        for name in args.apps if repetition % 2 else list(reversed(args.apps)):
            for count in args.clients if args.case == "cable" else [0]:
                label = f"{name}-{repetition}-{args.case}" + (f"-{count}" if count else "")
                measure(name, repetition, args.case, args.out / label, count)


if __name__ == "__main__":
    main()
