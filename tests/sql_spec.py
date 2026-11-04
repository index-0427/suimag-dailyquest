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
        eq(value("daily_visit", "reward_amount"), "150000", "reward snapshot")
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
        # Real production 3/2 board transactions, distinct from the full-catalog collector fixtures.
        meta = payload["boardMeta"]

        def board_plan(name, owner="DRAW"):
            items = PLANS[name]
            return "START TRANSACTION;\n" + ";\n".join(
                bind(item["query"], [owner if v == "DRAW" else v for v in item["values"]])
                for item in items
            ) + ";\nCOMMIT;"

        def board_ids(owner="DRAW"):
            return scalar("SELECT CONCAT(period_kind,':',slot,':',quest_id) FROM suimag_dailyquest_assignments "
                          f"WHERE citizenid='{owner}' AND active=1 ORDER BY period_kind,slot;")

        execute(board_plan("board_prefs"))
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: execute(board_plan("board_draw")), range(8)))
        ids = board_ids()
        eq(len(ids.splitlines()), 5, "initial race creates five assignments exactly")
        eq(sum(line.startswith("daily:") for line in ids.splitlines()), 3, "three daily slots")
        eq(sum(line.startswith("weekly:") for line in ids.splitlines()), 2, "two weekly slots")
        eq("house" in ids or "boosting" in ids or "duty" in ids, False, "exclusions applied")
        eq(len(PLANS["board_draw_again"]), 0, "reconnect does not draw again")
        execute(board_plan("board_prefs_change"))
        eq(board_ids(), ids, "preference updates do not change assignments")
        # An old unselected completed record cannot be claimed via a forged callback.
        execute(statement("ensure", ["DRAW","daily_house","daily",1793736000,1793822400,1,"bank","",1000]))
        execute("UPDATE suimag_dailyquest_progress SET progress=target WHERE citizenid='DRAW' AND quest_id='daily_house';")
        unselected = int(scalar("SELECT id FROM suimag_dailyquest_progress WHERE citizenid='DRAW' AND quest_id='daily_house';"))
        eq(scalar(statement("reserve",[1793736110,unselected,"DRAW",1793736110])+";SELECT ROW_COUNT();"),"0","unassigned payout rejected")
        execute(statement("ensure", ["DRAW",meta["dailyReplacement"],"daily",1793736000,1793822400,99999,"bank","",1000]))
        execute(f"UPDATE suimag_dailyquest_progress SET progress=99 WHERE citizenid='DRAW' AND quest_id='{meta['dailyReplacement']}';")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: execute(board_plan("board_reroll_daily")), range(8)))
        eq(len(board_ids().splitlines()),5,"reroll retains five slots")
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='DRAW' AND period_kind='daily';"),"1","daily reroll used once")
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='DRAW' AND period_kind='weekly';"),"0","weekly allowance independent")
        eq(scalar(f"SELECT progress FROM suimag_dailyquest_progress WHERE citizenid='DRAW' AND quest_id='{meta['dailyReplacement']}';"),"0","replacement starts at zero")
        eq(scalar(f"SELECT active FROM suimag_dailyquest_assignments WHERE citizenid='DRAW' AND quest_id='{meta['daily']}';"),"0","old quest retired")
        execute(f"UPDATE suimag_dailyquest_progress SET progress=12 WHERE citizenid='DRAW' AND quest_id='{meta['dailyReplacement']}';")
        execute(board_plan("board_reroll_daily"))
        eq(scalar(f"SELECT progress FROM suimag_dailyquest_progress WHERE citizenid='DRAW' AND quest_id='{meta['dailyReplacement']}';"),"12","replaying reroll cannot reset progress again")
        execute(board_plan("board_reroll_weekly"))
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='DRAW' AND period_kind='weekly';"),"1","weekly reroll independently works")
        # Completed, claimed and pending quests all keep their slot and allowance.
        for status in ("complete","claimed","pending"):
            owner = "BLOCK_" + status
            execute(board_plan("board_draw",owner))
            before = board_ids(owner)
            if status == "complete":
                execute(f"UPDATE suimag_dailyquest_progress SET progress=target WHERE citizenid='{owner}' AND quest_id='{meta['daily']}';")
            else:
                execute(f"UPDATE suimag_dailyquest_progress SET status='{status}' WHERE citizenid='{owner}' AND quest_id='{meta['daily']}';")
            execute(board_plan("board_reroll_daily",owner))
            eq(board_ids(owner),before,status+" quest cannot be replaced")
            eq(scalar(f"SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='{owner}' AND period_kind='daily';"),"0",status+" rejection preserves allowance")
        # Failure after quota reservation rolls back the retirement and the quota together.
        execute(board_plan("board_draw","ROLLBACK"))
        before = board_ids("ROLLBACK")
        chunks=PLANS["board_reroll_daily"]
        broken="START TRANSACTION;"+";".join(bind(q["query"],["ROLLBACK" if v=="DRAW" else v for v in q["values"]]) for q in chunks[:2])+";INSERT INTO absent VALUES (1);COMMIT;"
        eq(execute(broken,check=False).returncode!=0,True,"reroll failure injection")
        eq(board_ids("ROLLBACK"),before,"rollback preserves assignments")
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='ROLLBACK' AND period_kind='daily';"),"0","rollback restores allowance")
        execute(board_plan("board_reroll_daily","ROLLBACK"))
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='ROLLBACK' AND period_kind='daily';"),"1","rollback can retry")
        # Time before assignment is not retroactively credited to a new quest.
        assigned_time=int(scalar("SELECT assigned_at FROM suimag_dailyquest_assignments WHERE citizenid='DRAW' AND quest_id='daily_time';"))
        execute(statement("time",[assigned_time+5,assigned_time-10,"DRAW","daily_time",1793736000]))
        eq(scalar("SELECT progress FROM suimag_dailyquest_progress WHERE citizenid='DRAW' AND quest_id='daily_time';"),"5","time clipped to assignment")
        execute(board_plan("board_next_day"))
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='DRAW' AND period_kind='daily' AND period_start=1793822400;"),"0","daily reset restores one reroll")
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='DRAW' AND period_kind='weekly' AND period_start=1793563200;"),"1","daily reset does not restore weekly reroll")
        eq(scalar("SELECT COUNT(*) FROM suimag_dailyquest_assignments WHERE citizenid='DRAW' AND period_kind='daily' AND period_start=1793822400 AND active=1;"),"3","new day gets three assignments")
        execute(board_plan("board_next_week"))
        eq(scalar("SELECT rerolls_used FROM suimag_dailyquest_boards WHERE citizenid='DRAW' AND period_kind='weekly' AND period_start=1794168000;"),"0","weekly reset restores one reroll")
        eq(scalar("SELECT COUNT(*) FROM suimag_dailyquest_assignments WHERE citizenid='DRAW' AND period_kind='weekly' AND period_start=1794168000 AND active=1;"),"2","new week gets two assignments")
        # Common rewards and the daily all-clear ledger use actual assignment rows.
        execute(board_plan("board_open_rewards"))
        day = 1793736000

        def bonus_value(column, owner="DRAW", start=day):
            return scalar(f"SELECT {column} FROM suimag_dailyquest_bonuses WHERE citizenid='{owner}' AND period_start={start};")

        bonus_id = int(bonus_value("id"))
        eq(bonus_value("required_count"),"3","bonus freezes the required slot count")
        eq(bonus_value("reward_amount"),"200000","daily completion amount")
        eq(scalar("SELECT GROUP_CONCAT(DISTINCT reward_amount) FROM suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a "
                  "ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start "
                  "WHERE p.citizenid='DRAW' AND p.period_kind='daily' AND p.period_start=1793736000 AND a.active=1;"),
           "150000","all selected daily rewards are uniform")
        eq(scalar("SELECT GROUP_CONCAT(DISTINCT reward_amount) FROM suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a "
                  "ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start "
                  "WHERE p.citizenid='DRAW' AND p.period_kind='weekly' AND p.period_start=1793563200 AND a.active=1;"),
           "500000","all selected weekly rewards are uniform")
        reserve_bonus = statement("reserveBonus",[1793736110,bonus_id,"DRAW",1793736110])
        eq(scalar(reserve_bonus+";SELECT ROW_COUNT();"),"0","partial completion cannot claim bonus")
        execute("UPDATE suimag_dailyquest_progress SET progress=target WHERE citizenid='DRAW' AND period_kind='weekly';")
        execute(f"UPDATE suimag_dailyquest_progress SET progress=target WHERE citizenid='DRAW' AND quest_id='{meta['daily']}';")
        eq(scalar(reserve_bonus+";SELECT ROW_COUNT();"),"0","weekly and retired quests do not count")
        execute("UPDATE suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a "
                "ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start "
                "SET p.progress=p.target WHERE p.citizenid='DRAW' AND p.period_kind='daily' "
                "AND p.period_start=1793736000 AND a.active=1 AND a.slot<=2;")
        eq(scalar(reserve_bonus+";SELECT ROW_COUNT();"),"0","two out of three is insufficient")
        execute("UPDATE suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a "
                "ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start "
                "SET p.progress=p.target WHERE p.citizenid='DRAW' AND p.period_kind='daily' AND p.period_start=1793736000 AND a.active=1;")
        eq(execute(statement("bonusState",["DRAW",day])).stdout.strip().split("\t")[-2:],["3","3"],"bonus state counts exactly current slots")
        eq(scalar(statement("reserveBonus",[1793736110,bonus_id,"OTHER",1793736110])+";SELECT ROW_COUNT();"),"0","bonus character isolation")
        # A corrupt/extra active slot cannot make the completion condition easier.
        execute(f"UPDATE suimag_dailyquest_assignments SET active=1 WHERE citizenid='DRAW' AND quest_id='{meta['daily']}' AND period_start={day};")
        eq(scalar(reserve_bonus+";SELECT ROW_COUNT();"),"0","unexpected assignment count rejects bonus")
        execute(f"UPDATE suimag_dailyquest_assignments SET active=0 WHERE citizenid='DRAW' AND quest_id='{meta['daily']}' AND period_start={day};")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(lambda _:scalar(reserve_bonus+";SELECT ROW_COUNT();"),range(8)))
        eq(sorted(results),["0"]*7+["1"],"only one concurrent bonus reservation")
        eq(bonus_value("status"),"pending","bonus reservation survives connection changes")
        eq("daily_bonus" in execute(SQL["pending"]).stdout,True,"bonus appears in pending diagnostics")
        execute(statement("syncBonusReward",["bank",999999,"DRAW",1793736110,1793736110]))
        eq(bonus_value("reward_amount"),"200000","pending bonus amount is immutable")
        execute(statement("releaseBonus",[bonus_id]))
        eq(bonus_value("status"),"active","explicit provider failure restores bonus eligibility")
        execute(statement("syncBonusReward",["bank",210000,"DRAW",1793736110,1793736110]))
        eq(bonus_value("reward_amount"),"210000","unclaimed bonus accepts common reward update")
        execute(board_plan("board_open_rewards"))
        eq(bonus_value("reward_amount"),"200000","common configuration reapplied")
        eq(scalar(reserve_bonus+";SELECT ROW_COUNT();"),"1","failed provider can retry bonus")
        execute(statement("finishBonus",[1793736111,bonus_id]))
        eq(bonus_value("status"),"claimed","bonus finalization")
        execute(statement("syncBonusReward",["bank",999999,"DRAW",1793736110,1793736110]))
        eq(bonus_value("reward_amount"),"200000","claimed bonus amount is immutable")
        eq(scalar(reserve_bonus+";SELECT ROW_COUNT();"),"0","claimed bonus cannot repeat")
        # Existing paid/pending per-quest amounts are never overwritten by common reward refresh.
        chosen=scalar("SELECT quest_id FROM suimag_dailyquest_assignments WHERE citizenid='DRAW' AND period_kind='daily' "
                      "AND period_start=1793736000 AND active=1 ORDER BY slot;").splitlines()
        for qid,status,amount in zip(chosen,["claimed","pending","active"],[1111,2222,3333]):
            execute(f"UPDATE suimag_dailyquest_progress SET status='{status}',reward_amount={amount} WHERE citizenid='DRAW' AND quest_id='{qid}' AND period_start={day};")
        execute(board_plan("board_open_rewards"))
        amounts=scalar("SELECT p.reward_amount FROM suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a "
                       "ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start "
                       "WHERE p.citizenid='DRAW' AND p.period_kind='daily' AND p.period_start=1793736000 AND a.active=1 ORDER BY a.slot;")
        eq(amounts.splitlines(),["1111","2222","150000"],"only unclaimed quest amounts change")
        # The next day gets a separate bonus and requires new completion.
        execute(board_plan("board_open_rewards_next_day"))
        next_bonus=int(bonus_value("id",start=1793822400))
        eq(next_bonus!=bonus_id,True,"next day uses a different bonus record")
        eq(bonus_value("status",start=1793822400),"active","next day bonus is unclaimed")
        eq(scalar(statement("reserveBonus",[1793822500,next_bonus,"DRAW",1793822500])+";SELECT ROW_COUNT();"),"0","yesterday completion does not unlock today")
        execute("UPDATE suimag_dailyquest_progress p JOIN suimag_dailyquest_assignments a "
                "ON a.citizenid=p.citizenid AND a.quest_id=p.quest_id AND a.period_start=p.period_start "
                "SET p.progress=p.target WHERE p.citizenid='DRAW' AND p.period_kind='daily' AND p.period_start=1793822400 AND a.active=1;")
        eq(scalar(statement("reserveBonus",[1793822500,next_bonus,"DRAW",1793822500])+";SELECT ROW_COUNT();"),"1","today completion unlocks today bonus")
        execute(statement("finishBonus",[1793822501,next_bonus]))
        # Expired active bonuses are not claimable even if the player completed all tasks.
        execute(board_plan("board_draw","EXPIRED_BONUS"))
        execute(board_plan("board_open_rewards","EXPIRED_BONUS"))
        execute("UPDATE suimag_dailyquest_progress SET progress=target WHERE citizenid='EXPIRED_BONUS';")
        expired_id=int(bonus_value("id",owner="EXPIRED_BONUS"))
        eq(scalar(statement("reserveBonus",[1793822400,expired_id,"EXPIRED_BONUS",1793822400])+";SELECT ROW_COUNT();"),"0","expired bonus rejected")
        execute(board_plan("board_open_rewards"))
        eq(scalar("SELECT COUNT(*) FROM suimag_dailyquest_bonuses WHERE citizenid='DRAW' AND period_start=1793736000;"),"1","opening repeatedly never duplicates a bonus")
        print(f"sql: {checks} assertions passed (isolated MariaDB, no network)")
    finally:
        daemon.terminate()
        try:
            daemon.wait(timeout=15)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait(timeout=5)
