#!/usr/bin/env python3
"""Builds a small branch-and-merge story on the iris database, for plot_iris.py.

Everything happens over the MySQL wire against the running compose stack.
Idempotent: it resets to the `demo-start` tag first, so run it as often as
you like. The story it leaves behind:

    main:           demo-start ── outlier fix ── merge of bigger-setosa
    bigger-setosa:  setosa petals rescaled x1.8   (merged into main)
    drop-virginica: virginica rows deleted        (left unmerged)

Each edit is chosen to be obvious in a scatter plot, so switching branches
and revisions in plot_iris.py visibly moves or removes clusters.

    python make_history.py              # defaults to 127.0.0.1:3306
    python make_history.py --port 3307  # when running alongside iris-stack
"""

import argparse
import sys

import pymysql

OUR_BRANCHES = ("bigger-setosa", "drop-virginica")


def q(cur, sql, params=None):
    cur.execute(sql, params)
    return cur.fetchall()


def step(title):
    print(f"\n=== {title}")


def show_log(cur, ref):
    for h, who, date, msg in q(
        cur,
        "SELECT commit_hash, committer, date, message FROM DOLT_LOG(%s) ORDER BY date",
        (ref,),
    ):
        print(f"  {h[:8]}  {date:%Y-%m-%d %H:%M}  {who:<12}  {msg}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    args = ap.parse_args()

    try:
        # One connection for everything: DOLT_CHECKOUT is session-scoped, so
        # splitting these calls across connections would edit the wrong branch.
        conn = pymysql.connect(
            host=args.host, port=args.port, user="demo", password="demo",
            database="iris", autocommit=True,
        )
    except pymysql.err.OperationalError as e:
        sys.exit(f"cannot connect to dolt at {args.host}:{args.port} ({e})\n"
                 "is the stack running?  docker compose up -d")

    cur = conn.cursor()

    tags = [t for (t,) in q(cur, "SELECT tag_name FROM dolt_tags")]
    if "demo-start" not in tags:
        sys.exit("tag 'demo-start' not found — the database has not been seeded.\n"
                 "run: docker compose up -d   (first start seeds itself)")

    step("Resetting to the pristine demo-start tag (idempotent)")
    q(cur, "CALL DOLT_CHECKOUT('main')")
    for (b,) in q(cur, "SELECT name FROM dolt_branches WHERE name IN %s", (OUR_BRANCHES,)):
        q(cur, "CALL DOLT_BRANCH('-D', %s)", (b,))
        print(f"  deleted leftover branch {b}")
    q(cur, "CALL DOLT_RESET('--hard', 'demo-start')")
    print("  main is back at demo-start; history before the tag is untouched:")
    show_log(cur, "main")

    step("Branch 'bigger-setosa': rescale setosa petals x1.8 (a unit fix)")
    q(cur, "CALL DOLT_CHECKOUT('-b', 'bigger-setosa')")
    q(cur, """UPDATE iris
              SET petal_length = ROUND(petal_length * 1.8, 1),
                  petal_width  = ROUND(petal_width  * 1.8, 1)
              WHERE species = 'setosa'""")
    q(cur, "CALL DOLT_COMMIT('-A', '-m', 'Rescale setosa petals: recorded in the wrong units')")
    print("  the setosa cluster moves up and to the right in the petal plot")

    step("Branch 'drop-virginica': delete a whole species")
    q(cur, "CALL DOLT_CHECKOUT('-b', 'drop-virginica', 'main')")
    q(cur, "DELETE FROM iris WHERE species = 'virginica'")
    q(cur, "CALL DOLT_COMMIT('-A', '-m', 'Drop virginica pending relabelling (50 rows)')")
    print("  one of the three clusters vanishes on this branch")

    step("Meanwhile on main: an unrelated one-row fix, so the merge is a real 3-way")
    q(cur, "CALL DOLT_CHECKOUT('main')")
    q(cur, "UPDATE iris SET sepal_width = 3.1 WHERE id = 42")
    q(cur, "CALL DOLT_COMMIT('-A', '-m', 'Correct sepal_width outlier on row 42')")

    step("Merge 'bigger-setosa' into main ('drop-virginica' stays unmerged)")
    q(cur, "CALL DOLT_MERGE('bigger-setosa', '-m', \"Merge branch 'bigger-setosa'\")")

    step("Where things ended up")
    print("main:")
    show_log(cur, "main")
    print("drop-virginica (diverges from demo-start):")
    show_log(cur, "drop-virginica")
    print("\nbranches:")
    for name, hash_ in q(cur, "SELECT name, hash FROM dolt_branches ORDER BY name"):
        print(f"  {name:<16} {hash_[:8]}")

    print("\nNow run:  python plot_iris.py")
    print("Pick a branch or an old commit and watch the clusters move.")


if __name__ == "__main__":
    main()
