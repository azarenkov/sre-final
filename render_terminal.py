import sys
from pathlib import Path

import matplotlib.pyplot as plt


def render(text: str, out_path: str, title: str = "") -> None:
    text = text.rstrip("\n")
    lines = text.split("\n")
    n_lines = len(lines)
    longest = max((len(line) for line in lines), default=80)

    width = max(8.5, min(longest * 0.085 + 1.0, 18))
    height = max(2.0, n_lines * 0.22 + (0.6 if title else 0.4))

    fig, ax = plt.subplots(figsize=(width, height), dpi=150)
    fig.patch.set_facecolor("#0f172a")
    ax.set_facecolor("#0f172a")
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_color("#334155")

    title_offset = 0.18 if title else 0.04
    if title:
        ax.text(
            0.01, 0.985,
            title,
            family="monospace",
            color="#94a3b8",
            fontsize=10,
            transform=ax.transAxes,
            verticalalignment="top",
        )

    ax.text(
        0.01, 1.0 - title_offset,
        text,
        family="monospace",
        color="#e2e8f0",
        fontsize=11,
        transform=ax.transAxes,
        verticalalignment="top",
        linespacing=1.25,
    )

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout(pad=0.4)
    fig.savefig(out_path, dpi=150, facecolor=fig.get_facecolor())
    plt.close(fig)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: render_terminal.py <input-text-file> <output-png> [title]")
        return 1
    in_path, out_path = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else ""
    text = Path(in_path).read_text()
    render(text, out_path, title)
    print(f"saved {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
