#!/usr/bin/env bash
# Generates docker-compose.yml — the single self-contained file you hand to
# someone else. Embeds the canonical Iris CSV and the seed script inline, so
# the result has no dependencies beyond Docker and an internet connection.
#
#   ./build-demo.sh            # regenerates docker-compose.yml
#   docker compose up          # runs the demo
#
# Re-run this only if you change the source CSV or the seed logic.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_CSV="${1:-/home/danb/dolt-iris/iris.csv}"
OUT="$HERE/docker-compose.yml"

[ -f "$SRC_CSV" ] || { echo "source CSV not found: $SRC_CSV" >&2; exit 1; }

python3 - "$SRC_CSV" "$OUT" <<'PYEOF'
import sys, csv, io

src, out = sys.argv[1], sys.argv[2]

# Add an explicit id column so imported ids are deterministic rather than
# depending on AUTO_INCREMENT following file order.
with open(src) as f:
    rows = list(csv.reader(f))
header, data = rows[0], rows[1:]
if header[:5] != ["sepal_length", "sepal_width", "petal_length", "petal_width", "species"]:
    sys.exit(f"unexpected CSV header: {header}")
if len(data) != 150:
    sys.exit(f"expected 150 rows, got {len(data)}")

csv_lines = ["id," + ",".join(header)]
for i, r in enumerate(data, start=1):
    csv_lines.append(f"{i}," + ",".join(r))
csv_block = "\n".join(csv_lines)

def indent(text, n):
    pad = " " * n
    return "\n".join(pad + line if line.strip() else line for line in text.split("\n"))

# NOTE ON $$: compose interpolates the whole YAML, including dockerfile_inline
# and command blocks. Every literal shell $ must therefore be written $$ here.
compose = f"""# Dolt demo — version-controlled Iris dataset.
#
# ONE FILE. Everything is inline; there is nothing else to download.
#
#   docker compose up -d          # start (first run seeds itself, ~30s)
#   docker compose run --rm demo  # guided tour of what Dolt can do
#   docker compose down -v        # remove everything, including data
#
# Web UI:  http://localhost:3000   (connection is pre-configured)
# SQL:     mysql -h 127.0.0.1 -P 3306 -u demo -pdemo -D iris --ssl-mode=DISABLED
#
# GENERATED FILE — edit build-demo.sh instead.

name: iris-demo

services:

  # ---------------------------------------------------------------------
  # The database. Seeds itself on first start with a backdated history.
  # ---------------------------------------------------------------------
  dolt:
    build:
      dockerfile_inline: |
        # syntax=docker/dockerfile:1.7
        FROM dolthub/dolt-sql-server:2.1.10

        COPY <<'IRISCSV' /seed/iris.csv
{indent(csv_block, 8)}
        IRISCSV

        COPY <<'SEEDSH' /seed/seed.sh
        #!/bin/bash
        # Seeds the demo repo at RUNTIME, not build time. This is deliberate:
        # the commit dates are computed relative to *now*, so "yesterday" is
        # always genuinely yesterday no matter when this image is run. Baking
        # the history at build time would make the time-travel demo silently
        # return today's data once the image is a few days old.
        set -euo pipefail

        DEMO=/var/lib/dolt/iris
        export HOME=/home/dolt

        if [ ! -d "$$DEMO/.dolt" ]; then
          echo "[seed] first run — building backdated demo history"
          mkdir -p "$$DEMO"
          cd "$$DEMO"

          D3=$$(date -d '3 days ago 09:00' +%Y-%m-%dT%H:%M:%S)
          D3B=$$(date -d '3 days ago 09:20' +%Y-%m-%dT%H:%M:%S)
          # The bad edit sits TWO days back, not one, on purpose. The demo asks
          # "what was it yesterday?" via NOW() - INTERVAL 1 DAY, which resolves
          # to yesterday at the current time of day. Dating the bad edit
          # "yesterday 14:30" would make that question return the *pristine*
          # value whenever the demo is run before 14:30 — no story at all.
          # Two days back means all of yesterday is inside the broken window,
          # so the question works at any hour.
          D2=$$(date -d '2 days ago 14:30' +%Y-%m-%dT%H:%M:%S)

          dolt config --global --add user.name  "Ada Lovelace"  >/dev/null
          dolt config --global --add user.email "ada@example.com" >/dev/null
          # `dolt init --date` is documented but silently ignored in 2.1.10 —
          # the root commit always lands at "now", leaving a parent newer than
          # its children. Amending it afterwards does work.
          dolt init >/dev/null
          dolt commit --amend --date "$$D3" -m "Initialize data repository" --allow-empty >/dev/null

          dolt sql -q "CREATE TABLE iris (
            id int NOT NULL AUTO_INCREMENT,
            sepal_length decimal(3,1) NOT NULL,
            sepal_width  decimal(3,1) NOT NULL,
            petal_length decimal(3,1) NOT NULL,
            petal_width  decimal(3,1) NOT NULL,
            species varchar(20) NOT NULL,
            PRIMARY KEY (id),
            KEY species (species)
          )"
          dolt table import -u iris /seed/iris.csv >/dev/null 2>&1
          dolt add -A
          dolt commit --date "$$D3B" -m "Import canonical Iris dataset (150 rows)" >/dev/null

          # --- Two days ago: someone "fixes" a value that was never broken ---
          dolt config --global --add user.name  "Bob Miller" >/dev/null
          dolt config --global --add user.email "bob@example.com" >/dev/null
          dolt sql -q "UPDATE iris SET petal_width = 0.9 WHERE id = 4"
          dolt add -A
          dolt commit --date "$$D2" -m "Fix suspected data-entry error on row 4" >/dev/null
          BAD=$$(dolt sql -q "SELECT commit_hash FROM dolt_log LIMIT 1" -r csv | tail -1)

          # --- Today: caught and reverted, so HEAD is the pristine dataset --
          dolt config --global --add user.name  "Ada Lovelace" >/dev/null
          dolt config --global --add user.email "ada@example.com" >/dev/null
          dolt revert "$$BAD" >/dev/null
          echo "[seed] bad commit was $$BAD (reverted)"

          # Marks the pristine starting point so the tour can reset to it and
          # be run repeatedly without erroring on branches that already exist.
          dolt tag demo-start -m "clean starting state for the demo" >/dev/null

          # Users must exist before the server starts. Creating them offline
          # writes .doltcfg/privileges.db, which the server reads on boot.
          dolt --doltcfg-dir /var/lib/dolt/.doltcfg sql -q "
            CREATE USER IF NOT EXISTS 'demo'@'%' IDENTIFIED BY 'demo';
            GRANT ALL PRIVILEGES ON *.* TO 'demo'@'%' WITH GRANT OPTION;
          " >/dev/null

          # The workbench keeps its saved connections here.
          mkdir -p /var/lib/dolt/dolt_workbench
          cd /var/lib/dolt/dolt_workbench && dolt init --date "$$D3" >/dev/null

          echo "[seed] done"
        else
          echo "[seed] existing data found — skipping seed"
        fi

        exec docker-entrypoint.sh "$$@"
        SEEDSH

        COPY <<'SRVCFG' /etc/dolt/servercfg.d/config.yaml
        log_level: warning
        listener:
          host: 0.0.0.0
          port: 3306
        data_dir: /var/lib/dolt
        privilege_file: /var/lib/dolt/.doltcfg/privileges.db
        SRVCFG

        RUN mkdir -p /home/dolt /.dolt /var/lib/dolt/.doltcfg \\
            && chmod +x /seed/seed.sh

        ENTRYPOINT ["/seed/seed.sh"]
    container_name: iris-demo-dolt
    ports:
      - "3306:3306"
    volumes:
      - demo-data:/var/lib/dolt
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/3306"]
      interval: 5s
      timeout: 3s
      retries: 20
      start_period: 20s
    restart: unless-stopped

  # ---------------------------------------------------------------------
  # Reachability guard. The dolt healthcheck tests 127.0.0.1 from INSIDE
  # dolt's own network namespace, so it reports "healthy" even when the
  # container is attached to no network and nothing can reach it. This
  # checks from a *different* container, which is the only way to catch it.
  #
  # Without this guard the failure surfaces inside the workbench as
  # "No metadata for DatabaseConnectionsEntity" — which points at the
  # datastore and sends you looking in completely the wrong place.
  # ---------------------------------------------------------------------
  reachability-guard:
    image: dolthub/dolt-sql-server:2.1.10
    container_name: iris-demo-guard
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -u
        # `timeout 3` per attempt is essential. When the container is orphaned
        # the hostname does not resolve, and docker's embedded DNS answers
        # EAI_AGAIN and retries rather than failing — so a bare /dev/tcp probe
        # BLOCKS for minutes instead of erroring, and this guard would hang
        # silently instead of printing the diagnosis below.
        for i in $$(seq 1 30); do
          timeout 3 bash -c 'exec 3<>/dev/tcp/dolt/3306' 2>/dev/null && {{ echo "dolt reachable over the compose network."; exit 0; }}
          sleep 2
        done
        echo "======================================================================"
        echo "FATAL: cannot reach dolt:3306 over the compose network."
        echo
        echo "The dolt container is almost certainly orphaned from the network."
        echo "This happens when the first 'up' hit a port clash on 3306 (something"
        echo "else on your machine is using it — often a local MySQL), leaving a"
        echo "container that later restarts attached to no network at all."
        echo
        echo "Fix:    docker compose up -d --force-recreate"
        echo "Check:  ss -ltnp | grep 3306"
        echo "======================================================================"
        exit 1
    depends_on:
      dolt:
        condition: service_healthy
    restart: "no"

  # ---------------------------------------------------------------------
  # Web UI. Its connection is pre-seeded, so there is nothing to type.
  # ---------------------------------------------------------------------
  workbench:
    image: dolthub/dolt-workbench:latest
    container_name: iris-demo-workbench
    ports:
      - "3000:3000"   # UI
      - "9002:9002"   # backend API the browser calls — both are required
    environment:
      # Without a datastore the workbench forgets every saved connection.
      # Pointing it at dolt itself avoids shipping a second database.
      DW_DB_HOST: dolt
      DW_DB_PORT: "3306"
      DW_DB_USER: demo
      DW_DB_PASS: demo
      DW_DB_DBNAME: dolt_workbench
      DW_DB_USE_SSL: "false"
    depends_on:
      dolt:
        condition: service_healthy
      # Must not start until dolt is provably reachable. The workbench builds
      # its TypeORM DataSource lazily and caches it EVEN ON FAILURE, so if it
      # touches an unreachable dolt once it stays wedged on
      # "No metadata for DatabaseConnectionsEntity" until restarted.
      reachability-guard:
        condition: service_completed_successfully
    restart: unless-stopped

  # Pre-populates the workbench connection. Idempotent; runs once and exits.
  workbench-init:
    image: curlimages/curl:latest
    container_name: iris-demo-workbench-init
    depends_on:
      workbench:
        condition: service_started
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        set -eu
        API=http://workbench:9002/graphql

        # The workbench creates its connection table lazily on first query,
        # so this poll both waits for readiness and triggers table creation.
        i=0
        until curl -sf -X POST "$$API" -H 'Content-Type: application/json' \\
              -d '{{"query":"{{ storedConnections {{ name }} }}"}}' >/tmp/out 2>/dev/null; do
          i=$$((i+1))
          [ "$$i" -gt 90 ] && echo "workbench API never came up" && exit 1
          sleep 2
        done

        if grep -q 'Iris' /tmp/out; then
          echo "connection already stored"
          exit 0
        fi

        cat > /tmp/q.json <<'JSON'
        {{"query":"mutation {{ addDatabaseConnection(name: \\"Iris (Dolt)\\", connectionUrl: \\"mysql://demo:demo@dolt:3306/iris\\", type: Mysql, useSSL: false, hideDoltFeatures: false, isLocalDolt: false) {{ currentDatabase }} }}"}}
        JSON
        curl -sf -X POST "$$API" -H 'Content-Type: application/json' -d @/tmp/q.json
        echo
        echo "workbench connection ready -> http://localhost:3000"
    restart: "no"

  # ---------------------------------------------------------------------
  # An "external computer": a MySQL client, no dolt, no data.
  #   docker compose run --rm demo        -> guided tour
  #   docker compose run --rm demo bash   -> poke around yourself
  # ---------------------------------------------------------------------
  demo:
    build:
      dockerfile_inline: |
        # syntax=docker/dockerfile:1.7
        FROM ubuntu:24.04
        RUN apt-get update \\
            && apt-get install -y --no-install-recommends mysql-client ca-certificates \\
            && rm -rf /var/lib/apt/lists/*

        COPY <<'TOUR' /usr/local/bin/tour
        #!/usr/bin/env bash
        # Guided tour. Every query here is plain SQL over the wire — this
        # container has no dolt binary and no copy of the data.
        set -uo pipefail
        Q() {{ mysql -h dolt -P 3306 -u demo -pdemo -D iris --ssl-mode=DISABLED -t "$$@" 2>&1 | grep -v "\\[Warning\\]"; }}
        QN() {{ mysql -h dolt -P 3306 -u demo -pdemo -D iris --ssl-mode=DISABLED -N -B "$$@" 2>/dev/null; }}
        P() {{ echo; echo "=============================================================="; echo "$$1"; echo "=============================================================="; }}

        # Reset to the pristine tagged state so this tour can be run as many
        # times as you like. Without this, a second run dies on "branch already
        # exists" and on main having already been merged.
        QN -e "CALL DOLT_CHECKOUT('main');" >/dev/null 2>&1
        for b in $$(QN -e "SELECT name FROM dolt_branches WHERE name <> 'main';"); do
          QN -e "CALL DOLT_BRANCH('-D','$$b');" >/dev/null 2>&1
        done
        for t in $$(QN -e "SELECT tag_name FROM dolt_tags WHERE tag_name <> 'demo-start';"); do
          QN -e "CALL DOLT_TAG('-d','$$t');" >/dev/null 2>&1
        done
        QN -e "CALL DOLT_RESET('--hard','demo-start');" >/dev/null 2>&1

        P "1. This is an ordinary MySQL client. No dolt installed here."
        command -v dolt >/dev/null && echo "dolt present" || echo "  -> no dolt binary. Everything below is just SQL over TCP."
        Q -e "SELECT COUNT(*) AS rows_in_iris FROM iris;"

        P "2. TIME TRAVEL: what was row 4's petal_width yesterday?"
        echo "   (AS OF needs TIMESTAMP() — a bare date string is read as a branch name)"
        Q -e "SELECT id, petal_width AS yesterday FROM iris AS OF TIMESTAMP(NOW() - INTERVAL 1 DAY) WHERE id = 4;"
        echo "   ...and today:"
        Q -e "SELECT id, petal_width AS today FROM iris WHERE id = 4;"

        P "3. WHY did it change? The history of that one row."
        Q -e "SELECT commit_hash, committer, commit_date, petal_width
              FROM dolt_history_iris WHERE id = 4 ORDER BY commit_date;"

        P "4. WHO touched it? Blame, per row."
        # NB: the column is `commit` (a reserved word, hence the backticks),
        # not commit_hash as in dolt_log/dolt_history_*.
        Q -e "SELECT \\`commit\\`, committer, commit_date, message
              FROM dolt_blame_iris WHERE id = 4;"

        P "5. The full audit log — version control as queryable SQL."
        Q -e "SELECT commit_hash, committer, date, message FROM dolt_log ORDER BY date;"

        P "6. BRANCH: two analysts work in parallel, nobody blocks anybody."
        # All in ONE session: DOLT_CHECKOUT is session-scoped, so splitting
        # these across separate mysql invocations would update the wrong branch.
        # active_branch() is kept out of the aggregate — mixing it with COUNT(*)
        # trips only_full_group_by.
        Q -e "CALL DOLT_CHECKOUT('-b','alice');
              UPDATE iris SET species='setosa-verified' WHERE id BETWEEN 1 AND 10;
              CALL DOLT_COMMIT('-A','-m','alice: verify first 10 rows');
              SELECT COUNT(*) AS verified_on_alice
              FROM iris WHERE species='setosa-verified';"
        echo "   main is untouched:"
        Q -e "SELECT COUNT(*) AS verified_on_main FROM iris WHERE species='setosa-verified';"

        P "7. DIFF two branches — row-level, not a text diff."
        # `rows` is reserved — aliasing to it is a syntax error.
        Q -e "SELECT from_species, to_species, COUNT(*) AS n
              FROM dolt_diff('main','alice','iris') GROUP BY 1,2;"

        P "8. MERGE alice into main."
        Q -e "CALL DOLT_MERGE('alice');
              SELECT COUNT(*) AS verified_on_main_now FROM iris WHERE species='setosa-verified';"

        P "9. CONFLICT: two branches change the SAME row differently."
        Q -e "CALL DOLT_CHECKOUT('-b','carol');
              UPDATE iris SET petal_width=5.5 WHERE id=1;
              CALL DOLT_COMMIT('-A','-m','carol: row 1 -> 5.5');" >/dev/null 2>&1
        Q -e "CALL DOLT_CHECKOUT('-b','dave','main');
              UPDATE iris SET petal_width=7.7 WHERE id=1;
              CALL DOLT_COMMIT('-A','-m','dave: row 1 -> 7.7');" >/dev/null 2>&1
        echo "   carol says row 1 is 5.5; dave says 7.7. Merging dave into carol."
        echo
        # dolt_allow_commit_conflicts is REQUIRED. With autocommit on (the
        # default) a conflicting merge is rolled back wholesale and the
        # conflicts are thrown away — you would see "conflicts found" and then
        # an empty dolt_conflicts table. The whole cycle must also stay in one
        # session, since conflicts live in that session's working set.
        Q -e "SET @@dolt_allow_commit_conflicts = 1;
              CALL DOLT_CHECKOUT('carol');
              CALL DOLT_MERGE('dave');
              SELECT 'the conflict is queryable DATA, not a wall of text' AS note;
              SELECT base_petal_width AS base, our_petal_width AS ours,
                     their_petal_width AS theirs FROM dolt_conflicts_iris;
              CALL DOLT_CONFLICTS_RESOLVE('--ours','iris');
              CALL DOLT_COMMIT('-A','-m','resolve: keep carol');
              SELECT petal_width AS resolved_to FROM iris WHERE id=1;"

        P "10. TAG a release, so a paper can cite an exact dataset version."
        Q -e "CALL DOLT_CHECKOUT('main'); CALL DOLT_TAG('v1.0','main','-m','published dataset');
              SELECT tag_name, message FROM dolt_tags;"
        echo "   and query the tag directly, forever:"
        Q -e "SELECT COUNT(*) AS rows_at_v1 FROM iris AS OF 'v1.0';"

        P "Done. Try the UI at http://localhost:3000 — branches and diffs are visual there."
        echo
        TOUR
        RUN chmod +x /usr/local/bin/tour
        CMD ["tour"]
    container_name: iris-demo-client
    profiles: ["tools"]
    stdin_open: true
    tty: true
    depends_on:
      dolt:
        condition: service_healthy

volumes:
  demo-data:
"""

with open(out, "w") as f:
    f.write(compose)
print("wrote %s (%d bytes, %d data rows embedded)" % (out, len(compose), len(data)))
PYEOF

echo "Now run:  cd $HERE && docker compose up -d"
