#!/usr/bin/env python3
"""
Frame pace plot from Mayfair traces: each dot is a frame, time runs down the strip, and how far
right it sits is how long the frame took. One strip per trace, side by side, for comparing runs.

    MAYFAIR_TRACE=gpu.txt dub run -- Animation
    MAYFAIR_RENDERER=cpu MAYFAIR_TRACE=cpu.txt dub run -- Animation
    python3 framepace.py gpu.txt:WebGPU cpu.txt:CPU -o pace.png

A trace can also be a WAYLAND_DEBUG=client log, of this or any other app whose frames ask for
wp_presentation feedback (Vulkan's Fifo present mode does, through Mesa):

    WAYLAND_DEBUG=client dub run -- Animation 2> shown.log
    python3 framepace.py shown.log:Shown

Then each dot is a frame as the compositor showed it, at the vblank it went out on: what's on the
screen, where a Mayfair trace has when the frame was handed over. Locked to the display, every dot
is on the dashed line; one a refresh late is twice as far out. It has no layout, work or GC to say.

--metric interval (the default) is the time since the previous frame: pacing, what you see.
--metric work is layout + paint + present: what the frame cost. With a present mode that waits
for the display, present includes that wait, so work is only meaningful as an upper bound.

Blue dots are frames an animation asked for, grey ones frames an event caused. With
--animating-only the grey ones are left out, as the gap before them is idle time, not jank.
Red ones had a garbage collection since the frame before: in the loop's wait, where it's meant to
be, or in the app's code, mid-frame. Each strip's numbers say how many there were of each.
"""
import argparse
import re

import matplotlib.pyplot as plt
from matplotlib.lines import Line2D

FRAME = re.compile(r"^\s*([\d.]+)\s+frame .*?layout ([\d.]+)\s+paint ([\d.]+)\s+present ([\d.]+)"
                   r"\s+total ([\d.]+) ms(?:\s+animating (\d))?(?:\s+gc (\d+)\s+between (\d+))?")
REFRESH = re.compile(r"refresh ([\d.]+) Hz")
# wp_presentation_feedback.presented(tv_sec_hi, tv_sec_lo, tv_nsec, refresh_ns, seq_hi, seq_lo, flags)
PRESENTED = re.compile(r"wp_presentation_feedback#\d+\.presented\((\d+), (\d+), (\d+), (\d+), \d+, \d+, \d+\)")

SURFACE, PANEL, GRID = "#0d0f14", "#12151c", "#2a2e38"
TEXT, MUTED = "#ffffff", "#8b8f99"
ANIMATED, EVENT, COLLECTED = "#3987e5", "#9a9a92", "#e5484d"


def load(path):
    frames, hz, first = [], 60.0, None
    with open(path) as f:
        for line in f:
            if m := PRESENTED.search(line):
                shown = ((int(m[1]) << 32) + int(m[2])) * 1000 + int(m[3]) / 1e6
                first = shown if first is None else first
                if int(m[4]):
                    hz = 1e9 / int(m[4])
                frames.append({"t": shown - first, "work": 0.0, "animating": True, "gc": 0, "between": 0})
            elif m := REFRESH.search(line):
                hz = float(m[1]) or hz
            elif m := FRAME.match(line):
                frames.append({"t": float(m[1]), "work": float(m[5]),
                               "animating": m[6] == "1" if m[6] is not None else True,
                               "gc": int(m[7] or 0), "between": int(m[8] or 0)})
    prev = None
    for fr in frames:
        fr["interval"] = fr["t"] - prev if prev is not None else None
        prev = fr["t"]
    return frames, hz


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("traces", nargs="+", help="trace file, optionally path:Label")
    ap.add_argument("--metric", choices=["interval", "work"], default="interval")
    ap.add_argument("--max-ms", type=float, default=80, help="right edge; slower frames are pinned there")
    ap.add_argument("--skip-ms", type=float, default=0, help="leave out the first N ms (startup)")
    ap.add_argument("--animating-only", action="store_true")
    ap.add_argument("-o", "--output", help="image to write; shows a window without it")
    args = ap.parse_args()

    runs = []
    for spec in args.traces:
        path, _, label = spec.partition(":")
        runs.append((label or path, *load(path)))

    fig, axes = plt.subplots(1, len(runs), figsize=(3.4 * len(runs), 7), squeeze=False, facecolor=SURFACE)
    duration = max((fr["t"] for _, frames, _ in runs for fr in frames), default=1)

    for ax, (label, frames, hz) in zip(axes[0], runs):
        budget = 1000 / hz
        shown = [fr for fr in frames
                 if fr["t"] >= args.skip_ms and fr[args.metric] is not None
                 and (fr["animating"] or not args.animating_only)]
        # An interval ending in an event frame is mostly idle, so it's not in the numbers
        paced = [fr[args.metric] for fr in shown if fr["animating"]]

        ax.set_facecolor(PANEL)
        ax.axvline(budget, color=MUTED, lw=1, ls=(0, (4, 4)), zorder=1)
        # Frames with a collection are drawn last, over the rest, so none hides behind another
        for colour, group in ((EVENT, [fr for fr in shown if not fr["animating"] and not fr["gc"]]),
                              (ANIMATED, [fr for fr in shown if fr["animating"] and not fr["gc"]]),
                              (COLLECTED, [fr for fr in shown if fr["gc"]])):
            ax.scatter([min(fr[args.metric], args.max_ms) for fr in group], [fr["t"] / 1000 for fr in group],
                       s=14, color=colour, edgecolors=PANEL, linewidths=0.6, zorder=3)
        for fr in shown:  # beyond the edge: an arrow says so, and how long it was
            if fr[args.metric] > args.max_ms:
                y = fr["t"] / 1000
                ax.annotate(f"{fr[args.metric]:.0f}", (args.max_ms, y), xytext=(-22, 0), textcoords="offset points",
                            color=MUTED, fontsize=7, va="center", ha="right",
                            arrowprops=dict(arrowstyle="->", color=MUTED, lw=0.8))

        ax.set_xlim(0, args.max_ms * 1.02)
        ax.set_ylim(duration / 1000, args.skip_ms / 1000)  # time runs downwards
        ax.set_xticks([0, budget, args.max_ms], [f"0ms", f"{budget:.1f}ms", f"{args.max_ms:.0f}ms"])
        ax.tick_params(colors=MUTED, labelsize=8, length=0)
        ax.set_ylabel("time (s)", color=MUTED, fontsize=8)
        ax.grid(axis="y", color=GRID, lw=0.5)
        for side in ax.spines.values():
            side.set_visible(False)

        if paced:
            ordered = sorted(paced)
            p99 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))]
            late = sum(v > budget * 1.5 for v in paced)
            stats = (f"{len(paced)} animated frames, {hz:.0f} Hz\n"
                     f"median {ordered[len(ordered) // 2]:.1f}  p99 {p99:.1f}  max {ordered[-1]:.1f} ms\n"
                     f"{late} over 1.5× budget")
        else:
            stats = f"{len(shown)} frames, none animated"
        collections = sum(fr["gc"] for fr in shown)
        between = sum(fr["between"] for fr in shown)
        stats += f"\n{collections} GC: {between} between frames, {collections - between} mid-frame"
        ax.set_title(label, color=TEXT, fontsize=11, loc="left", fontweight="bold", pad=54)
        ax.text(0, 1.005, stats, transform=ax.transAxes, color=MUTED, fontsize=7.5, va="bottom")

    fig.legend(handles=[Line2D([], [], marker="o", ls="", color=ANIMATED, label="animation frame"),
                        Line2D([], [], marker="o", ls="", color=EVENT, label="event frame"),
                        Line2D([], [], marker="o", ls="", color=COLLECTED, label="garbage collected")],
               loc="lower center", ncol=3, frameon=False, labelcolor=MUTED, fontsize=8)
    fig.suptitle(f"Frame pace — {'frame interval' if args.metric == 'interval' else 'frame work time'}",
                 color=TEXT, fontsize=12, x=0.02, ha="left")
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    if args.output:
        fig.savefig(args.output, dpi=150, facecolor=SURFACE)
    else:
        plt.show()


if __name__ == "__main__":
    main()
