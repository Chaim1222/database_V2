"""Isolated 0030/0031 comparison. Standard library + local PostgreSQL only."""
import concurrent.futures
import json
import os
from pathlib import Path
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
ROWS_WIKI = 400000
ROWS_MECH = 380000
BATCH = 500
REPEATS = 3
PREFIX = f"v2_m31_bench_{os.getpid()}"


def sql(db, statement, app="m31-benchmark"):
    result = subprocess.run(
        ["psql", "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-d", db],
        input=statement, text=True, capture_output=True, check=True,
        env={**os.environ, "PGAPPNAME": app, "PGOPTIONS": "-c statement_timeout=120000 -c lock_timeout=10000"},
    )
    return result.stdout.strip()


MEASURE = """
create function pg_temp.measure(p_sql text) returns jsonb language plpgsql as $$
declare started timestamptz; elapsed double precision;
begin
    started := clock_timestamp();
    execute p_sql;
    elapsed := extract(epoch from clock_timestamp()-started)*1000;
    return jsonb_build_object('ms',elapsed);
end $$;
"""


def measure(db, statement, app="m31-benchmark"):
    output = sql(db, MEASURE + "begin; select pg_temp.measure($measure$" + statement + "$measure$); rollback;", app)
    return json.loads(output.splitlines()[-1])["ms"]


def seed(db):
    sql(db, (ROOT / "db/tests/00_supabase_stub.sql").read_text())
    for path in sorted((ROOT / "db/migrations").glob("*.sql")):
        if path.name[:4] <= "0030":
            sql(db, "begin;" + path.read_text() + "commit;")
    sql(db, f"""
        insert into mirror.wiki_page(page_id,title,latest_rev_id)
            select i, 'synthetic article '||i, i from generate_series(1,{ROWS_WIKI}) i;
        insert into mirror.mech_page(page_id,title,status)
            select i, 'synthetic article '||i, 'created_in_mech' from generate_series(1,{ROWS_MECH}) i;
        insert into derived.wiki_gap(wiki_id,kind)
            select i, 'missing' from generate_series({ROWS_MECH}+1,{ROWS_WIKI}) i;
        analyze;
    """)


def insertion(start=2000000):
    return f"insert into mirror.wiki_page(page_id,title) select i,'bench new '||i from generate_series({start},{start+BATCH-1}) i;"


def payload(start, new=False):
    prefix = "bench new " if new else "synthetic article "
    return f"(select jsonb_agg(jsonb_build_object('page_id',i,'title','{prefix}'||i)) from generate_series({start},{start+BATCH-1}) i)"


def parallel(db):
    # Hold each transaction 100 ms deliberately: a locking demonstration, not a forecast.
    blocked = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(measure, db, insertion(3000000 + i*BATCH) + "select pg_sleep(0.1);", f"m31-writer-{i}") for i in range(4)]
        while not all(f.done() for f in futures):
            blocked.append(int(sql(db, "select count(*) from pg_stat_activity where application_name like 'm31-writer-%' and wait_event_type='Lock';") or 0))
            time.sleep(0.02)
        return {"writer_ms": [f.result() for f in futures], "max_observed_lock_waiters": max(blocked, default=0), "lock_samples": len(blocked), "intentional_hold_ms": 100}


def run():
    if os.environ.get("PGHOST", "/var/run/postgresql") not in ("/var/run/postgresql", "localhost", "127.0.0.1"):
        raise RuntimeError("Benchmark refuses remote PGHOST; use a disposable local PostgreSQL server")
    created, results = [], {}
    try:
        for variant in ("0030", "0031"):
            db = PREFIX + "_" + variant
            sql("postgres", f'create database "{db}";')
            created.append(db)
            seed(db)
            if variant == "0031":
                sql(db, "begin;" + (ROOT / "db/migrations/0031_exact_mirror_counts.sql").read_text() + "commit;")
            scenarios = {
                "insert_500": insertion(),
                "unchanged_upsert_500": f"insert into mirror.wiki_page as w(page_id,title) select i,'synthetic article '||i from generate_series(1,{BATCH}) i on conflict(page_id) do update set title=excluded.title where w.title is distinct from excluded.title;",
                "delete_500": f"delete from mirror.wiki_page where page_id between 1 and {BATCH};",
                "sync_insert_500": "select api.sync_apply_wiki_pages(" + payload(2000000, True) + ");",
                "sync_replay_500": "select api.sync_apply_wiki_pages(" + payload(1) + ");",
                "sync_delete_500": f"select api.sync_apply_wiki_pages('[]',array(select i::bigint from generate_series(1,{BATCH}) i));",
                "refresh_counts": "select ops.refresh_counts();",
                "read_5000": "select * from api.reconcile_pages('wikipedia',0,5000);",
            }
            samples = {}
            for name, statement in scenarios.items():
                measure(db, statement)  # warm-up, rolled back like every measured write
                values = [measure(db, statement) for _ in range(REPEATS)]
                samples[name] = {"ms": values, "median_ms": statistics.median(values), "max_ms": max(values)}
                print(variant, name, json.dumps(samples[name]), flush=True)
            samples["parallel_writes"] = [parallel(db) for _ in range(REPEATS)]
            counts = json.loads(sql(db, "select jsonb_build_object('wiki', (select count(*) from mirror.wiki_page), 'mech',(select count(*) from mirror.mech_page));"))
            if counts != {"wiki": ROWS_WIKI, "mech": ROWS_MECH}:
                raise RuntimeError("Measured transactions did not roll back")
            if variant == "0031":
                exact = json.loads(sql(db, "select jsonb_object_agg(key,n) from ops.mirror_count;"))
                if exact != {"wiki_pages": ROWS_WIKI, "mech_pages": ROWS_MECH}:
                    raise RuntimeError("Counter drifted after rollback/concurrent writers")
            results[variant] = samples
        document = {"environment": {"postgres": sql(created[0], "show server_version;"), "wiki_rows": ROWS_WIKI, "mech_rows": ROWS_MECH, "batch": BATCH, "repeats": REPEATS, "synthetic": True, "warmed_samples": True}, "results": results}
        Path("benchmark-results.json").write_text(json.dumps(document, indent=2))
        lines = ["# Migration 0031: isolated synthetic comparison", "", "Server-side times; warmed samples; 400,000 wiki / 380,000 mech rows. This is not a production measurement.", "", "| Operation | 0030 median ms | 0031 median ms |", "|---|---:|---:|"]
        for name in scenarios:
            lines.append(f"| {name} | {results['0030'][name]['median_ms']:.2f} | {results['0031'][name]['median_ms']:.2f} |")
        lines += ["", "Parallel writes deliberately hold each transaction 100 ms. Durations include that hold. Lock observations are samples, not exact cumulative waiting time.", "", "```json", json.dumps({v: results[v]['parallel_writes'] for v in results}, indent=2), "```", "", "Counts and counters stayed correct after rollback. No production connection, real titles, Supabase secrets or migrations were used against a live database. Estimates in 0030 remain estimates; timing does not prove production suitability."]
        report = "\n".join(lines)
        Path("benchmark-results.md").write_text(report)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
                fh.write(report + "\n")
    finally:
        for db in reversed(created):
            sql("postgres", f'drop database if exists "{db}";')


if __name__ == "__main__":
    run()
