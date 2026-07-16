#!/usr/bin/env python3
"""Scatter-plot the iris table at any branch, tag, or commit.

Interactive by default: pick a ref in the left-hand panel, then a commit from
that ref's history below it, and the plot re-queries dolt over the MySQL wire
and redraws. Run make_history.py first for a history worth exploring.

    python plot_iris.py                                   # interactive
    python plot_iris.py --ref drop-virginica --save x.png # headless snapshot
    python plot_iris.py --port 3307 ...                   # alongside iris-stack

Axis limits are fixed on purpose: when the data changes the POINTS move,
rather than the axes quietly rescaling around them.
"""

import argparse
import sys

import pymysql

# Fixed colors per species so a species keeps its color across revisions.
# Anything unexpected (e.g. 'setosa-verified' from the guided tour) gets gray.
COLORS = {"setosa": "tab:blue", "versicolor": "tab:orange", "virginica": "tab:green"}
SEPAL_XLIM, SEPAL_YLIM = (4.0, 8.5), (1.5, 5.0)
PETAL_XLIM, PETAL_YLIM = (0.0, 8.0), (0.0, 8.0)
MAX_COMMITS = 12


def q(cur, sql, params=None):
    cur.execute(sql, params)
    return cur.fetchall()


def fetch_refs(cur):
    """Branches plus tags, as (label, ref) pairs."""
    refs = [(b, b) for (b,) in q(cur, "SELECT name FROM dolt_branches ORDER BY name")]
    refs += [(f"tag: {t}", t) for (t,) in q(cur, "SELECT tag_name FROM dolt_tags ORDER BY tag_name")]
    return refs


def fetch_commits(cur, ref):
    """Newest-first (label, hash) pairs for a ref's history."""
    rows = q(cur, "SELECT commit_hash, message FROM DOLT_LOG(%s) ORDER BY date DESC", (ref,))
    return [(f"{h[:8]} {m[:34]}", h) for h, m in rows[:MAX_COMMITS]]


def fetch_iris(cur, ref):
    return q(cur, "SELECT sepal_length, sepal_width, petal_length, petal_width, species "
                  "FROM iris AS OF %s", (ref,))


def expand(lim, values, pad=0.3):
    """The fixed limit, grown just enough to include any out-of-range data.
    Never shrinks below the fixed range, so ordinary revisions stay stable."""
    if not values:
        return lim
    return (min(lim[0], min(values) - pad), max(lim[1], max(values) + pad))


def draw(fig, sepal_ax, petal_ax, rows, title):
    for ax in (sepal_ax, petal_ax):
        ax.clear()
    by_species = {}
    for sl, sw, pl, pw, sp in rows:
        by_species.setdefault(sp, []).append((float(sl), float(sw), float(pl), float(pw)))
    for sp, pts in sorted(by_species.items()):
        color = COLORS.get(sp, "tab:gray")
        sepal_ax.scatter([p[0] for p in pts], [p[1] for p in pts],
                         c=color, label=f"{sp} ({len(pts)})", alpha=0.7, edgecolors="none")
        petal_ax.scatter([p[2] for p in pts], [p[3] for p in pts],
                         c=color, alpha=0.7, edgecolors="none")
    cols = list(zip(*((p for pts in by_species.values() for p in pts)))) or [[], [], [], []]
    sepal_ax.set(xlim=expand(SEPAL_XLIM, cols[0]), ylim=expand(SEPAL_YLIM, cols[1]),
                 xlabel="sepal_length", ylabel="sepal_width", title="Sepals")
    petal_ax.set(xlim=expand(PETAL_XLIM, cols[2]), ylim=expand(PETAL_YLIM, cols[3]),
                 xlabel="petal_length", ylabel="petal_width", title="Petals")
    sepal_ax.legend(loc="upper right", fontsize=8)
    fig.suptitle(f"iris @ {title}   —   {len(rows)} rows", fontsize=12)
    fig.canvas.draw_idle()


def run_interactive(cur, fig, sepal_ax, petal_ax):
    from matplotlib.widgets import Button, RadioButtons
    import matplotlib.pyplot as plt

    button_ax = fig.add_axes([0.015, 0.935, 0.10, 0.05])
    ref_ax = fig.add_axes([0.015, 0.60, 0.24, 0.30])
    commit_ax = fig.add_axes([0.015, 0.06, 0.24, 0.48])

    state = {"refs": [], "commits": [], "ref_label": None,
             "ref_radio": None, "commit_radio": None, "rebuilding": False}

    def shrink(radio, size):
        for t in radio.labels:
            t.set_fontsize(size)

    def on_commit(label):
        if state["rebuilding"]:
            return
        h = dict(state["commits"])[label]
        draw(fig, sepal_ax, petal_ax, fetch_iris(cur, h), label)

    def on_ref(label):
        if state["rebuilding"]:
            return
        state["ref_label"] = label
        ref = dict(state["refs"])[label]
        state["commits"] = fetch_commits(cur, ref)
        # RadioButtons can't relabel in place; rebuild the widget.
        state["rebuilding"] = True
        commit_ax.clear()
        commit_ax.set_title("commit", fontsize=9, loc="left")
        state["commit_radio"] = RadioButtons(commit_ax, [c[0] for c in state["commits"]])
        shrink(state["commit_radio"], 7)
        state["commit_radio"].on_clicked(on_commit)
        state["rebuilding"] = False
        # Draw the ref itself (its HEAD), which the first radio entry equals.
        draw(fig, sepal_ax, petal_ax, fetch_iris(cur, ref), label)

    def refresh(_event=None):
        """Re-query branches/tags and commits — picks up work done since the
        window opened. Keeps the current selection when it still exists."""
        state["refs"] = fetch_refs(cur)
        labels = [r[0] for r in state["refs"]]
        keep = state["ref_label"] if state["ref_label"] in labels else labels[0]
        state["rebuilding"] = True
        ref_ax.clear()
        ref_ax.set_title("branch / tag", fontsize=9, loc="left")
        state["ref_radio"] = RadioButtons(ref_ax, labels, active=labels.index(keep))
        shrink(state["ref_radio"], 8)
        state["ref_radio"].on_clicked(on_ref)
        state["rebuilding"] = False
        on_ref(keep)

    button = Button(button_ax, "refresh")
    button.label.set_fontsize(9)
    button.on_clicked(refresh)
    refresh()
    state["refresh"] = refresh  # kept for tests; widgets stay alive via state
    state["button"] = button
    plt.show()
    return state


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--ref", help="branch, tag, or commit hash (default: interactive)")
    ap.add_argument("--save", metavar="PNG", help="write the plot to a file instead of a window")
    args = ap.parse_args()

    if args.save:
        import matplotlib
        matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    try:
        conn = pymysql.connect(host=args.host, port=args.port, user="demo",
                               password="demo", database="iris", autocommit=True)
    except pymysql.err.OperationalError as e:
        sys.exit(f"cannot connect to dolt at {args.host}:{args.port} ({e})\n"
                 "is the stack running?  docker compose up -d")
    cur = conn.cursor()

    fig = plt.figure(figsize=(12, 6.5))
    sepal_ax = fig.add_axes([0.33, 0.10, 0.28, 0.78])
    petal_ax = fig.add_axes([0.68, 0.10, 0.28, 0.78])

    if args.ref or args.save:
        ref = args.ref or "main"
        draw(fig, sepal_ax, petal_ax, fetch_iris(cur, ref), ref)
        if args.save:
            fig.savefig(args.save, dpi=110)
            print(f"wrote {args.save}")
        else:
            plt.show()
    else:
        run_interactive(cur, fig, sepal_ax, petal_ax)


if __name__ == "__main__":
    main()
