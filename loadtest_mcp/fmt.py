"""Shared output formatting for the EMR on EKS load-test MCP tools.

Tool return values are plain strings rendered in a terminal / chat UI, so a
single house style keeps every tool's output scannable and consistent instead
of each one hand-rolling its own separators and status markers. The style is
"boxed + emoji": a Unicode box header, emoji status glyphs (✅/❌/⚠️), and
aligned key/value blocks.

Everything here is pure string work -- no I/O, no AWS -- so it's trivially
testable and safe to call from any tool.
"""

from __future__ import annotations

from typing import Iterable, Optional

# Status glyphs. Kept in one place so a client that can't render a given emoji
# can be retargeted with a single edit.
OK = "✅"
FAIL = "❌"
WARN = "⚠️"
INFO = "ℹ️"
RUN = "▶️"

# Box-drawing characters for headers.
_TL, _TR, _BL, _BR, _H, _V = "╭", "╮", "╰", "╯", "─", "│"

# Sensible bounds for the header box so short titles still look intentional and
# long ones don't sprawl. Content wider than MAX is not truncated -- the box
# just grows with it (a readable overflow beats a lossy one).
_MIN_INNER = 34
_MAX_INNER = 72


def status_glyph(ok: Optional[bool]) -> str:
    """Map a tri-state to a glyph: True→✅, False→❌, None→⚠️ (warn/unknown)."""
    if ok is True:
        return OK
    if ok is False:
        return FAIL
    return WARN


def header(title: str, subtitle: Optional[str] = None) -> str:
    """Render a boxed header with the title on the top border.

        ╭─ Cluster validation ─────────────╮
          16/16 checks passed
        ╰──────────────────────────────────╯

    ``subtitle`` (e.g. a pass count or one-line status) sits inside the box.
    """
    title_txt = f" {title} "
    inner = max(len(title_txt) + 2, _MIN_INNER)
    if subtitle:
        inner = max(inner, len(subtitle) + 2)
    inner = min(inner, max(_MAX_INNER, len(title_txt) + 2))

    # Top border: "╭─ title ──…──╮" -- one lead dash before the title, the rest
    # filling to the right edge.
    fill = inner - len(title_txt) - 1
    top = f"{_TL}{_H}{title_txt}{_H * max(fill, 0)}{_TR}"
    bottom = f"{_BL}{_H * inner}{_BR}"
    lines = [top]
    if subtitle:
        lines.append(f"  {subtitle}")
    lines.append(bottom)
    return "\n".join(lines)


def status_line(ok: Optional[bool], label: str, detail: str = "",
                label_width: int = 0) -> str:
    """One status row: ``✅ label   detail`` with the label padded to width."""
    lbl = label.ljust(label_width) if label_width else label
    return f"{status_glyph(ok)} {lbl}   {detail}".rstrip()


def status_block(rows: Iterable[tuple[Optional[bool], str, str]]) -> str:
    """Render aligned status rows from (ok, label, detail) tuples.

    The label column is padded to the widest label so the detail column lines
    up across every row.
    """
    rows = list(rows)
    width = max((len(label) for _ok, label, _detail in rows), default=0)
    return "\n".join(status_line(ok, label, detail, width)
                     for ok, label, detail in rows)


def kv(pairs: Iterable[tuple[str, str]], sep: str = "  ") -> str:
    """Render aligned key/value lines: keys padded to the widest key.

        Profile  bda
        Account  633458367150
        Region   us-west-2
    """
    pairs = [(k, v) for k, v in pairs]
    width = max((len(k) for k, _v in pairs), default=0)
    return "\n".join(f"{k.ljust(width)}{sep}{v}" for k, v in pairs)


def bullets(items: Iterable[str], marker: str = "•") -> str:
    """Render a simple bullet list."""
    return "\n".join(f"  {marker} {it}" for it in items)


def note(kind: Optional[bool], text: str) -> str:
    """A single glyph-prefixed note line (kind follows status_glyph tri-state)."""
    return f"{status_glyph(kind)} {text}"


def section(title: str, body: str, subtitle: Optional[str] = None) -> str:
    """A boxed header followed by a body block, with a trailing blank spacer."""
    return f"{header(title, subtitle)}\n\n{body}"
