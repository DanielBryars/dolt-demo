# Dolt demo — a version-controlled Iris dataset

`docker-compose.yml` is the whole thing. One file, ~18KB, nothing else to
download. Send it to someone and they run:

```bash
docker compose up -d          # first run seeds itself (~40s)
docker compose run --rm demo  # guided tour, 10 sections
```

Then <http://localhost:3000> for the web UI — **the connection is already
configured**, there is nothing to type.

```bash
docker compose down -v        # remove everything including data
```

Direct SQL access, from anywhere on the network:

```bash
mysql -h <host> -P 3306 -u demo -pdemo -D iris --ssl-mode=DISABLED
```

## What it shows

The seeded history is a small story: a clean import three days ago, then a
"fix" from a colleague two days ago that quietly changed row 4's `petal_width`
from 0.2 to 0.9, then a revert today. So HEAD is the pristine canonical Iris
dataset, but the past is real and queryable:

```sql
-- what was row 4's petal width yesterday?
SELECT petal_width FROM iris AS OF TIMESTAMP(NOW() - INTERVAL 1 DAY) WHERE id = 4;   -- 0.9
SELECT petal_width FROM iris WHERE id = 4;                                            -- 0.2
```

The tour covers: time travel, per-row history, blame, the audit log as SQL,
branching, row-level diff, merge, a real merge conflict resolved through
`dolt_conflicts_iris`, and tagging a citable release.

The key point for the audience: the `demo` container has **no dolt binary and
no copy of the data**. Everything is plain SQL over TCP. Nobody clones a 10GB
dataset to ask what changed.

## Regenerating

`docker-compose.yml` is generated. Edit `build-demo.sh` and re-run it:

```bash
./build-demo.sh
docker compose up -d --build     # --build is REQUIRED, see below
```

## Running alongside iris-stack

Both want ports 3306/3000/9002, so they cannot run at once. To run this demo
without stopping `iris-stack`:

```bash
docker compose -f docker-compose.yml -f alongside-iris-stack.yml up -d
# dolt on 3307, UI on 3010
```

`alongside-iris-stack.yml` is for local convenience — don't send it on.

---

## Gotchas found while building this (all worked around in the file)

**`AS OF` needs `TIMESTAMP()`.** `AS OF '2026-07-14 13:00:00'` fails with
"string is not a valid branch or hash" — a bare string is read as a ref. Use
`AS OF TIMESTAMP(NOW() - INTERVAL 1 DAY)`.

**Seeding happens at container start, not build time.** The commit dates are
computed relative to *now*, so "yesterday" is always genuinely yesterday. If the
history were baked at build time, the flagship question would silently start
returning today's data once the image was a few days old — the demo would look
like it proved nothing.

**The bad edit is dated two days back, not one.** `NOW() - INTERVAL 1 DAY`
resolves to yesterday *at the current time of day*. With the bad edit at
"yesterday 14:30", anyone running the demo before 14:30 would get the pristine
value and see no story at all. Two days back means all of yesterday sits inside
the broken window, so it works at any hour.

**`dolt init --date` is documented but does not work** (2.1.10) — the root
commit always lands at "now", leaving a parent newer than its children.
`dolt commit --amend --date` afterwards does work.

**Merge conflicts need `@@dolt_allow_commit_conflicts = 1`.** With autocommit on
(the default) a conflicting merge is rolled back wholesale: you get
"conflicts found" and then an *empty* `dolt_conflicts_iris`. The whole
merge → inspect → resolve → commit cycle must also happen in **one session**,
because conflicts live in that session's working set.

**`DOLT_CHECKOUT` is session-scoped.** Every `mysql -e` invocation is a new
session. Splitting checkout and update across two calls silently updates the
wrong branch. Same applies to `docker compose run` — each is a fresh connection.

**`dolt_blame_<table>` uses `commit`, not `commit_hash`** (unlike `dolt_log` and
`dolt_history_*`), and `commit` is reserved, so it needs backticks.

**`rows` is a reserved word** — `COUNT(*) AS rows` is a syntax error.

**`docker compose up` does NOT rebuild when `dockerfile_inline` changes.** It
silently reuses the cached image, so edits to the seed script appear to do
nothing. Use `--build`, or `build --no-cache` when iterating on the seed.

**The workbench needs a datastore or it forgets everything.** `DW_DB_*` env vars
point it at a MySQL-compatible store; here that is dolt itself, in a
`dolt_workbench` database. That database must exist *before* the workbench first
touches it: the workbench builds its TypeORM DataSource lazily and caches it
even on failure, so a missing database wedges it permanently on
"No metadata for DatabaseConnectionsEntity" until restarted. The seed creates it
up front.

**Both workbench ports matter.** 3000 is the UI, 9002 is the API the *browser*
calls. Publishing only 3000 gives a blank page.

## Security

`demo`/`demo` with full privileges, bound to 0.0.0.0. It is a demo — do not put
it on an untrusted network.
