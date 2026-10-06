#!/usr/bin/env python3
# gen-man-pages.py — generate tau(1) and tau-config(5) man pages.
#
#   scripts/gen-man-pages.py                     # regenerate man/ in place
#   scripts/gen-man-pages.py --outdir /tmp/man   # write elsewhere
#   scripts/gen-man-pages.py --version 0.5.0 --date 2026-10-06
#
# Sources of truth (regenerated — never hand-edit man/):
#   man/man1/tau.1          <- `tau --help` section/entry layout +
#                              `tau --help-json` exit codes +
#                              docs/configuration.md env-var table
#   man/man5/tau-config.5   <- docs/configuration.md config-key table,
#                              JSON example, provider table, key resolution
#
# Options:
#   --bin PATH     tau binary to interrogate (default: $TAU_BIN,
#                  else ./zig-out/bin/tau)
#   --outdir DIR   output directory (default: man/)
#   --version V    version stamped in .TH headers (default: parsed from
#                  src/version.zig)
#   --date D       date stamped in .TH headers (default: $SOURCE_DATE_EPOCH
#                  if set, else today's UTC date)
#   --config-doc F configuration reference (default: docs/configuration.md)
#   -h, --help     show this help
#
# The generated pages are checked into git; release archives bundle them
# verbatim. The smoke 'release' group re-derives flag/config-key coverage so a
# forgotten regeneration is caught before a release ships stale pages.

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fail(msg):
    print("gen-man-pages.py: %s" % msg, file=sys.stderr)
    sys.exit(1)


# ── roff helpers ────────────────────────────────────────────────────────────

def esc(text):
    """Escape text for inclusion in roff source."""
    text = text.replace("\\", "\\e")
    text = text.replace("-", "\\-")
    # man readability: map a few unicode glyphs that render poorly on
    # minimal terminals.
    for a, b in (("→", "->"), ("—", "\\(em"), ("–", "\\(en"),
                 ("≤", "<="), ("≥", ">="), ("×", "x")):
        text = text.replace(a, b)
    if text.startswith(".") or text.startswith("'"):
        text = "\\&" + text
    return text


def fmt_left(left):
    """Render an entry's command/flag column: flags bold, <args> italic,
    [brackets] roman."""
    out = []
    for tok in left.split(" "):
        if not tok:
            continue
        if tok.startswith("<") or tok.startswith("["):
            out.append("\\fI%s\\fR" % esc(tok))
        elif "]" in tok or ">" in tok:
            out.append("\\fI%s\\fR" % esc(tok))
        elif tok == "|":
            out.append(tok)
        else:
            out.append("\\fB%s\\fR" % esc(tok))
    return " ".join(out)


def th(name, section, date, version, manual):
    return '.TH %s %s "%s" "tau %s" "%s"' % (
        name, section, date, version, manual)


# ── tau --help parsing ─────────────────────────────────────────────────────

def parse_help(text):
    """Split `tau --help` into (tagline, [(title, intro_lines, entries)]).

    entries: list of [left_column, [desc_line, ...]] — continuation lines are
    detected purely by indentation (entries hang at cols 2-10, continuations
    sit deeper).
    """
    lines = text.splitlines()
    tagline = lines[0].strip() if lines else ""
    sections = []
    current = None
    for raw in lines[1:]:
        if not raw.strip():
            continue
        indent = len(raw) - len(raw.lstrip())
        stripped = raw.strip()
        if indent == 0 and stripped.endswith(":"):
            title = stripped[:-1].lstrip("\\").strip()
            current = [title, [], []]
            sections.append(current)
            continue
        if current is None:
            continue
        if indent <= 10:
            m = re.match(r"^(.*?)(?:\s{2,}(.*))?$", stripped)
            left, desc = m.group(1), m.group(2)
            if desc is None:
                # entries whose flag column overruns the description column
                # lose the 2+ space gap (e.g. "--coordinator-model <model>
                # Override ...") — split after the last > or ] token instead
                m2 = re.match(r"^(.*?[>\]])\s+([A-Z/].*)$", stripped)
                if m2:
                    left, desc = m2.group(1), m2.group(2)
            current[2].append([left, [desc] if desc else []])
        else:
            # continuation of the previous entry's description (or a stray
            # paragraph line if no entry exists yet)
            if current[2]:
                current[2][-1][1].append(stripped)
            else:
                current[1].append(stripped)
    return tagline, sections


def emit_entries(entries, whole_left=False):
    out = []
    for left, desc_lines in entries:
        out.append(".TP")
        out.append("\\fB%s\\fR" % esc(left) if whole_left else fmt_left(left))
        for i, d in enumerate(desc_lines):
            if i:
                out.append(".br")
            if d:
                out.append(esc(d))
    return out


# ── docs/configuration.md parsing ──────────────────────────────────────────

def md_clean(text):
    """Strip markdown inline formatting for roff embedding."""
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)   # [t](u) -> t
    text = text.replace("**", "")
    text = text.replace("`", "")
    text = text.replace("\\|", "|")
    return text.strip()


def md_rows(lines, start):
    """Yield cell-lists for consecutive table rows starting at index start."""
    rows = []
    i = start
    while i < len(lines) and lines[i].lstrip().startswith("|"):
        raw = lines[i].strip()
        cells = [md_clean(c) for c in re.split(r"(?<!\\)\|", raw)[1:-1]]
        if not all(re.fullmatch(r":?-+:?", c) for c in cells):
            rows.append(cells)
        i += 1
    return rows


def find_table(lines, heading_regex):
    """Return the data rows of the first table following a heading matching
    heading_regex."""
    for i, line in enumerate(lines):
        if re.match(heading_regex, line):
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith("|"):
                j += 1
            rows = md_rows(lines, j)
            return rows[1:] if rows else []  # drop the header row
    return []


def find_fence(lines, after_regex, lang):
    """Return the first fenced code block of a given language appearing after
    a line matching after_regex."""
    seen = False
    for i, line in enumerate(lines):
        if not seen and re.match(after_regex, line):
            seen = True
        if seen and line.strip() == "```" + lang:
            block = []
            j = i + 1
            while j < len(lines) and lines[j].strip() != "```":
                block.append(lines[j])
                j += 1
            return block
    return []


# ── page emitters ───────────────────────────────────────────────────────────

def emit_tau1(bin_path, doc_lines, date, version):
    try:
        help_text = subprocess.run(
            [bin_path, "--help"], capture_output=True, text=True,
            check=True).stdout
    except (OSError, subprocess.CalledProcessError) as e:
        fail("cannot run %s --help: %s" % (bin_path, e))
    try:
        help_json = json.loads(subprocess.run(
            [bin_path, "--help-json"], capture_output=True, text=True,
            check=True).stdout)
    except (OSError, subprocess.CalledProcessError,
            json.JSONDecodeError) as e:
        fail("cannot run %s --help-json: %s" % (bin_path, e))

    tagline, sections = parse_help(help_text)
    summary = tagline.split(" - ", 1)[-1] if " - " in tagline else tagline

    out = [
        '\\" tau.1 — generated by scripts/gen-man-pages.py; do not edit',
        th("TAU", "1", date, version, "Tau Manual"),
        ".SH NAME",
        "tau \\- %s" % esc(summary),
        ".SH DESCRIPTION",
        esc(tagline) + ".",
        ".PP",
        "tau reads prompts from argv (with \\fB@file\\fR injection), calls "
        "the configured LLM provider, optionally runs tool calls in an "
        "agentic loop, and prints the result on stdout. "
        "\\fB\\-\\-mode json\\fR (the default) emits JSON/NDJSON envelopes; "
        "\\fB\\-\\-mode text\\fR emits plain text. tau is designed for AI "
        "agents and CI pipelines rather than interactive use.",
    ]

    usage_entries = None
    for title, _intro, entries in sections:
        if title == "Usage":
            usage_entries = entries
    if usage_entries:
        out.append(".SH SYNOPSIS")
        for left, _ in usage_entries:
            parts = left.split(" ", 1)
            line = "\\fB%s\\fR" % esc(parts[0])
            if len(parts) > 1:
                line += " " + esc(parts[1])
            out.append(line)
            out.append(".br")

    section_names = {
        "Options": "OPTIONS",
        "Examples": "EXAMPLES",
    }
    for title, intro, entries in sections:
        if title == "Usage":
            continue
        sh = section_names.get(title, title.upper())
        out.append(".SH %s" % esc(sh))
        for p in intro:
            out.append(esc(p))
        out.extend(emit_entries(entries, whole_left=(title == "Examples")))

    env_rows = find_table(doc_lines, r"^### Read by tau itself")
    if env_rows:
        out.append(".SH ENVIRONMENT")
        for cells in env_rows:
            if len(cells) < 2:
                continue
            out.append(".TP")
            out.append("\\fB%s\\fR" % esc(cells[0]))
            out.append(esc(cells[1]))

    out.append(".SH FILES")
    for path, desc in (
        ("~/.config/tau/config.json",
         "Optional JSON configuration file; see \\fBtau\\-config\\fR(5)."),
        ("~/.config/tau/sessions/",
         "One JSON file per \\fB\\-\\-session\\fR name; conversation and "
         "goal state."),
        ("~/.config/tau/fleets/",
         "Fleet manifests written by \\fBtau fleet run\\fR."),
        ("~/.agents/skills/",
         "Skill directories autodiscovered by \\fBtau skills\\fR."),
    ):
        out.append(".TP")
        out.append("\\fB%s\\fR" % esc(path))
        out.append(desc)

    exit_codes = help_json.get("exit_codes") or {}
    if exit_codes:
        out.append(".SH EXIT STATUS")
        def _code_key(item):
            code, _desc = item
            return int(code) if str(code).isdigit() else 0
        for code, desc in sorted(exit_codes.items(), key=_code_key):
            out.append(".TP")
            out.append("\\fB%s\\fR" % esc(str(code)))
            out.append(esc(str(desc).replace("_", " ")))

    out.append(".SH SEE ALSO")
    out.append(
        "\\fBtau\\-config\\fR(5), "
        "\\fBtau guide\\fR (embedded operator manual), "
        "\\fBtau \\-\\-help\\fR, \\fBtau \\-\\-help\\-json\\fR")
    out.append(".PP")
    out.append("Full documentation: \\fIhttps://github.com/javimosch/tau\\fR")
    return "\n".join(out) + "\n"


def emit_tau_config5(doc_lines, date, version):
    keys_rows = find_table(doc_lines, r"^### All supported keys")
    prov_rows = find_table(doc_lines, r"^## Providers")
    json_block = find_fence(doc_lines, r"^### Example", "json")

    # ordered API-key resolution list under "### API key resolution"
    resolution = []
    in_sec = False
    for line in doc_lines:
        if re.match(r"^### API key resolution", line):
            in_sec = True
            continue
        if in_sec and re.match(r"^###? ", line):
            break
        if in_sec:
            m = re.match(r"^(\d+)\.\s+(.*)", line)
            if m:
                resolution.append(md_clean(m.group(2)))

    out = [
        '\\" tau-config.5 — generated by scripts/gen-man-pages.py; do not edit',
        th("TAU-CONFIG", "5", date, version, "Tau File Formats Manual"),
        ".SH NAME",
        "tau\\-config \\- tau configuration file",
        ".SH DESCRIPTION",
        "\\fB~/.config/tau/config.json\\fR (built from \\fB$HOME\\fR) is an "
        "optional JSON file read at startup. tau runs fine without it; "
        "behavior on load:",
        ".IP \\(bu 2",
        "Missing file, unreadable file, or unset \\fBHOME\\fR \\(-> all "
        "defaults are used.",
        ".IP \\(bu 2",
        "Invalid JSON \\(-> a warning is printed to stderr and defaults are "
        "used; tau does not exit.",
        ".IP \\(bu 2",
        "Unknown keys are ignored silently, so the file is "
        "forward\\-compatible.",
        ".PP",
        "Precedence: \\fBCLI flags > environment > config file > in\\-code "
        "defaults\\fR. Keys set in the file become the base config; matching "
        "CLI flags override them for that invocation.",
    ]

    if keys_rows:
        out.append('.SH "CONFIG KEYS"')
        for cells in keys_rows:
            if len(cells) < 5:
                continue
            key, typ, default, cli, notes = cells[:5]
            out.append(".TP")
            out.append("\\fB%s\\fR" % esc(key))
            meta = "Type: %s; default: %s." % (esc(typ), esc(default))
            if cli and cli != "—":
                meta += " CLI: \\fB%s\\fR." % esc(cli)
            out.append(meta)
            if notes:
                out.append(esc(notes))

    if json_block:
        out.append(".SH EXAMPLE")
        out.append(".nf")
        out.extend(esc(l) for l in json_block)
        out.append(".fi")

    if prov_rows:
        out.append(".SH PROVIDERS")
        for cells in prov_rows:
            if len(cells) < 5:
                continue
            name, endpoint, envs, model, window = cells[:5]
            out.append(".TP")
            out.append("\\fB%s\\fR" % esc(name))
            out.append("Endpoint: \\fI%s\\fR" % esc(endpoint))
            out.append(".br")
            out.append("Env vars tried in order: \\fB%s\\fR" % esc(envs))
            out.append(".br")
            out.append("Default model: \\fB%s\\fR; context window: %s tokens."
                       % (esc(model), esc(window)))

    if resolution:
        out.append('.SH "API KEY RESOLUTION"')
        out.append("The first non\\-empty value found wins:")
        for i, step in enumerate(resolution, 1):
            out.append(".IP %d. 4" % i)
            out.append(esc(step))

    out.append(".SH FILES")
    out.append(".TP")
    out.append("\\fB~/.config/tau/config.json\\fR")
    out.append("The configuration file itself.")
    out.append(".SH SEE ALSO")
    out.append("\\fBtau\\fR(1), "
               "\\fIhttps://github.com/javimosch/tau/blob/master/docs/"
               "configuration.md\\fR")
    return "\n".join(out) + "\n"


# ── main ────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="generate tau(1) and tau-config(5) man pages")
    ap.add_argument("--bin", default=os.environ.get(
        "TAU_BIN", os.path.join(ROOT, "zig-out/bin/tau")))
    ap.add_argument("--outdir", default=os.path.join(ROOT, "man"))
    ap.add_argument("--version", default=None)
    ap.add_argument("--date", default=None)
    ap.add_argument("--config-doc",
                    default=os.path.join(ROOT, "docs/configuration.md"))
    args = ap.parse_args()

    version = args.version
    if not version:
        try:
            src = open(os.path.join(ROOT, "src/version.zig")).read()
            version = re.search(r'version = "([^"]+)"', src).group(1)
        except (OSError, AttributeError):
            fail("cannot determine version — pass --version")

    date = args.date
    if not date:
        epoch = os.environ.get("SOURCE_DATE_EPOCH")
        if epoch:
            date = datetime.fromtimestamp(
                int(epoch), tz=timezone.utc).strftime("%Y-%m-%d")
        else:
            date = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    if not os.path.isfile(args.bin):
        fail("tau binary not found: %s (build with 'zig build' or pass --bin)"
             % args.bin)
    try:
        doc_lines = open(args.config_doc).read().splitlines()
    except OSError as e:
        fail("cannot read %s: %s" % (args.config_doc, e))

    man1 = emit_tau1(args.bin, doc_lines, date, version)
    man5 = emit_tau_config5(doc_lines, date, version)

    for rel, content in (("man1/tau.1", man1),
                         ("man5/tau-config.5", man5)):
        path = os.path.join(args.outdir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(content)
        print("gen-man-pages.py: wrote %s" % path, file=sys.stderr)


if __name__ == "__main__":
    main()
