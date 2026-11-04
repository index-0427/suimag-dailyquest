#!/usr/bin/env python3
"""Actual MariaDB tests. Starts only a disposable /tmp DB with networking disabled."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
payload = json.loads(subprocess.check_output(["lua", "tests/dump_sql.lua"], cwd=ROOT, text=True))
SQL, PLANS = payload["sql"], payload["plans"]
checks = 0


def eq(actual, expected, label):
    global checks
    checks += 1
    assert actual == expected, f"{label}: {actual!r} != {expected!r}"


def bind(sql, values):
    parts = sql.split("?")
    assert len(parts) == len(values) + 1
    result = parts[0]
    for value, suffix in zip(values, parts[1:]):
        if isinstance(value, str):
            value = "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"
        else:
            assert isinstance(value, int)
            value = str(value)
        result += value + suffix
    return result


def statement(name, values):
    return bind(SQL[name], values)


for tool in ("mariadb-install-db", "mariadbd", "mariadb", "lua"):
    if not shutil.which(tool):
        raise SystemExit(f"Required local test tool missing: {tool}")

with tempfile.TemporaryDirectory(prefix="suimag-dq-db-") as tmp:
    path = Path(tmp)
    data, socket = path / "data", path / "db.sock"
    install = subprocess.run(
        ["mariadb-install-db", "--no-defaults", f"--datadir={data}",
         "--auth-root-authentication-method=normal", "--skip-test-db"],
        capture_output=True, text=True,
    )
    if install.returncode:
        raise RuntimeError(install.stderr + install.stdout)
    daemon_args = [
        "mariadbd", "--no-defaults", f"--datadir={data}", f"--socket={socket}",
        "--skip-networking", f"--pid-file={path / 'db.pid'}",
        f"--log-error={path / 'db.log'}", "--innodb-buffer-pool-size=32M",
    ]
    if os.geteuid() == 0:
        daemon_args.append("--user=root")
    daemon = subprocess.Popen(daemon_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def execute(sql, database=True, check=True):
        args = ["mariadb", "--no-defaults", "--protocol=socket", f"--socket={socket}",
                "--user=root", "--batch", "--skip-column-names"]
        if database:
            args.append("dailyquest_test")
        result = subprocess.run(args, input=sql, capture_output=True, text=True, timeout=15)
        if check and result.returncode:
            raise RuntimeError(result.stderr)
        return result

    def scalar(sql):
        return execute(sql).stdout.strip()

    def plan(name):
        return "START TRANSACTION;\n" + ";\n".join(
            bind(item["query"], item["values"]) for item in PLANS[name]
        ) + ";\nCOMMIT;"

    def value(quest, column="progress", start=1793736000):
        return scalar(
            f"SELECT {column} FROM suimag_dailyquest_progress "
            f"WHERE citizenid='SQLTEST' AND quest_id='{quest}' AND period_start={start};"
        )

    try:
        for _ in range(200):
            if daemon.poll() is not None:
                raise RuntimeError((path / "db.log").read_text())
            if socket.exists() and execute("SELECT 1;", database=False, check=False).returncode == 0:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("Isolated MariaDB did not start")
        execute("CREATE DATABASE dailyquest_test;", database=False)
        schema = (ROOT / "sql/schema.sql").read_text()
        execute(schema)
        execute(schema)  # migration can run repeatedly
        execute(plan("open"))
        eq(scalar("SELECT COUNT(*) FROM suimag_dailyquest_progress;"), "42", "all quests created")
        eq(value("daily_visit"), "1", "daily attendance")
        week_start = 1793563200
        eq(value("weekly_visits", start=week_start), "1", "weekly attendance")
        execute(plan("open"))
        eq(scalar("SELECT COUNT(*) FROM suimag_dailyquest_visits;"), "1", "unique visits")
        execute(statement("ensure", ["SQLTEST", "daily_visit", "daily", 1793736000,
                                    1793822400, 99, "cash", "", 999999]))
        eq(value("daily_visit", "target"), "1", "target snapshot")
        eq(value("daily_visit", "reward_amount"), "1000", "reward snapshot")
        eq(value("daily_visit", "reward_type"), "bank", "reward type snapshot")
        # Real concurrent UPDATEs must reserve exactly once.
        claim_id = int(value("daily_visit", "id"))
        reserve = statement("reserve", [1793736100, claim_id, "SQLTEST", 1793736100])
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: scalar(reserve + "; SELECT ROW_COUNT();"), range(8)))
        eq(sorted(results), ["0"] * 7 + ["1"], "concurrent reservation")
        eq(value("daily_visit", "status"), "pending", "pending survives connection close")
        execute(statement("finish", [1793736101, claim_id]))
        eq(value("daily_visit", "status"), "claimed", "finalized")
        eq(scalar(reserve + "; SELECT ROW_COUNT();"), "0", "no repeat after finalize")
        # Incomplete, wrong-character and expired claims fail.
        time_id = int(value("daily_time", "id"))
        eq(scalar(statement("reserve", [1793736100, time_id, "SQLTEST", 1793736100]) +
                  "; SELECT ROW_COUNT();"), "0", "incomplete rejected")
        execute(statement("advance", [200000, "SQLTEST", "daily_time", 1793736000]))
        eq(value("daily_time"), "1800", "progress clamped")
        eq(scalar(statement("reserve", [1793736100, time_id, "OTHER", 1793736100]) +
                  "; SELECT ROW_COUNT();"), "0", "character restriction")
        eq(scalar(statement("reserve", [1793822400, time_id, "SQLTEST", 1793822400]) +
                  "; SELECT ROW_COUNT();"), "0", "expiry restriction")
        execute(statement("reserve", [1793736100, time_id, "SQLTEST", 1793736100]))
        execute(statement("release", [time_id]))
        eq(value("daily_time", "status"), "active", "explicit failure can retry")
        # Rollback is atomic across multiple updates.
        before = value("daily_meals")
        bad = execute("START TRANSACTION;" + statement("advance", [2, "SQLTEST", "daily_meals", 1793736000]) +
                      "; INSERT INTO missing_table VALUES (1); COMMIT;", check=False)
        eq(bad.returncode != 0, True, "forced SQL failure")
        eq(value("daily_meals"), before, "failed transaction rolled back")
        execute(plan("consume"))
        eq(value("daily_meals"), "1", "successful use")
        eq(value("weekly_meals", start=week_start), "1", "weekly use")
        # Replaying a receipt concurrently counts once in both periods.
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _: execute(plan("activity")), range(4)))
        eq(value("daily_delivery"), "1", "daily receipt dedupe")
        eq(value("weekly_delivery", start=week_start), "1", "weekly receipt dedupe")
        execute(plan("next_day"))
        eq(value("daily_visit", start=1793822400), "1", "new daily period")
        eq(value("weekly_visits", start=week_start), "2", "new visit day")
        execute("UPDATE suimag_dailyquest_progress SET progress=0 WHERE quest_id LIKE '%time';")
        execute(plan("time"))
        eq(value("daily_time"), "7", "time before reset")
        eq(value("daily_time", start=1793822400), "8", "time after reset")
        eq(value("weekly_time", start=week_start), "15", "weekly time conserved")
        execute(plan("next_week"))
        execute(plan("repeat_next_week"))
        eq(value("daily_delivery", start=1794340800), "0", "old receipt cannot replay next week")
        execute(plan("new_next_week"))
        eq(value("daily_delivery", start=1794340800), "1", "new receipt accepted")
        eq(value("weekly_visits", start=1794168000), "1", "weekly attendance resets")
        eq(len(execute(SQL["pending"]).stdout.splitlines()), 0, "no pending rows left")
        # Every shipped legacy activity writes its daily and weekly quest together.
        execute(plan("gate_open"))
        activities = ["bus", "garbage", "electrician", "postal", "taxi", "gruppe",
                      "fishing", "hunting", "construction", "cleaning", "recycle", "house", "boosting"]

        def gate_value(activity, period="weekly", start=week_start):
            return scalar("SELECT progress FROM suimag_dailyquest_progress "
                          f"WHERE citizenid='GATES' AND quest_id='{period}_{activity}' AND period_start={start};")

        for activity in activities:
            execute(plan("signal_" + activity))
            eq(gate_value(activity), "1", activity + " weekly completion")
            eq(gate_value(activity, "daily", 1793736000), "1", activity + " daily completion")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: execute(plan("signal_bus")), range(8)))
        eq(gate_value("bus"), "1", "same committed SQL token is not replayable")
        execute(plan("signal_duplicate"))
        execute(plan("signal_restarted"))
        eq(gate_value("bus"), "1", "rolling gate survives a new resource boot")
        execute(plan("signal_later"))
        eq(gate_value("bus"), "2", "new completion after cooldown")
        queries = PLANS["signal_rollback"]
        broken = "START TRANSACTION;" + ";".join(bind(q["query"], q["values"]) for q in queries[:3]) + ";INSERT INTO absent VALUES (1);COMMIT;"
        eq(execute(broken, check=False).returncode != 0, True, "signal failure injection")
        eq(gate_value("garbage"), "1", "signal rollback leaves progress unchanged")
        execute(plan("signal_rollback"))
        eq(gate_value("garbage"), "2", "rolled back signal can retry")
        execute(plan("signal_before_reset"))
        execute(plan("gate_next_day"))
        execute(plan("signal_after_reset"))
        eq(gate_value("bus", "daily", 1793822400), "0", "reset does not bypass rolling cooldown")
        execute(plan("signal_after_cooldown"))
        eq(gate_value("bus", "daily", 1793822400), "1", "first eligible new day completion")
        execute(plan("tracked"))
        eq(value("daily_walk"), "10", "tracked movement before reset")
        eq(value("daily_walk", start=1793822400), "15", "tracked movement after reset")
        eq(value("weekly_walk", start=week_start), "25", "tracked weekly movement")
        eq(value("daily_duty"), "2", "duty before reset")
        eq(value("daily_duty", start=1793822400), "3", "duty after reset")
        eq(value("weekly_duty", start=week_start), "5", "weekly duty conserved")
        print(f"sql: {checks} assertions passed (isolated MariaDB, no network)")
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=15)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=5)
