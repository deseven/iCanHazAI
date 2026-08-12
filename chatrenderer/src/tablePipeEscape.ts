// GFM tables treat a raw `|` as a cell delimiter even inside inline code
// spans — the spec requires `\|`, and GitHub/markdown-it enforce it. Models
// almost never emit that escape, so a cell like `` `a|b` `` silently
// truncates the whole row. Neither markdown-it nor markdown-it-ts will change
// this (spec-compliant), so we preprocess the source before block parsing:
// find table rows and escape pipes that sit inside code spans on those rows
// only. Escaping unconditionally is not an option — outside a table an
// escaped pipe inside a code span renders the backslash literally.
import type MarkdownItClass from "markdown-it-ts";

type MarkdownIt = InstanceType<typeof MarkdownItClass>;

const FENCE_OPEN_RE = /^ {0,3}(`{3,}|~{3,})(.*)$/;
const BLOCKQUOTE_PREFIX_RE = /^ *(?:> ?)+/;
const BLOCKQUOTE_ONLY_RE = /^ *(?:> *)+$/;
const INDENTED_CODE_RE = /^(?: {4}|\t)/;
const DELIMITER_CHARS_RE = /^[|\-: \t]+$/;
const DELIMITER_CELL_RE = /^:?-+:?$/;

// Line starts that end a table body, mirroring the block rules markdown-it
// uses as table terminators (its "blockquote" chain): heading, hr, list,
// html block, reference definition. Blockquote/fence/indented-code starts are
// handled separately.
const BODY_TERMINATOR_RES = [
    /^ {0,3}#{1,6}(?:\s|$)/,
    /^ {0,3}(?:\* *){3,}$/,
    /^ {0,3}(?:- *){3,}$/,
    /^ {0,3}(?:_ *){3,}$/,
    /^ {0,3}(?:[-+*]|\d{1,9}[.)]) /,
    /^ {0,3}<[/A-Za-z!?]/,
    /^ {0,3}\[[^\]]*\]:/,
];

function matchFenceOpen(line: string): { ch: string; len: number } | null {
    const m = FENCE_OPEN_RE.exec(line);
    if (!m) return null;
    // An info string containing a backtick makes it a paragraph, not a fence.
    if (m[1][0] === "`" && m[2].includes("`")) return null;
    return { ch: m[1][0], len: m[1].length };
}

function isFenceClose(line: string, ch: string, len: number): boolean {
    const run = ch === "`" ? "`" : "~";
    return new RegExp(`^ {0,3}${run}{${len},} *$`).test(line);
}

function isBlank(line: string): boolean {
    return line.trim() === "" || BLOCKQUOTE_ONLY_RE.test(line);
}

/** Mirrors the table rule's validation of the `|---|` delimiter row. */
function isDelimiterRow(line: string): boolean {
    if (INDENTED_CODE_RE.test(line)) return false;
    const s = line.replace(BLOCKQUOTE_PREFIX_RE, "").replace(/^ {0,3}/, "");
    if (s === "" || !DELIMITER_CHARS_RE.test(s)) return false;
    const cells = s.split("|");
    let count = 0;
    for (let i = 0; i < cells.length; i++) {
        const t = cells[i].trim();
        if (!t) {
            // Empty cells are only allowed from a leading/trailing pipe.
            if (i === 0 || i === cells.length - 1) continue;
            return false;
        }
        if (!DELIMITER_CELL_RE.test(t)) return false;
        count++;
    }
    return count > 0;
}

/** Escapes pipes inside code spans on a single table-row line. */
function escapePipesInCodeSpans(line: string): string {
    if (!line.includes("|") || !line.includes("`")) return line;
    let out = "";
    let i = 0;
    const n = line.length;
    while (i < n) {
        const ch = line[i];
        if (ch === "\\") {
            out += line.slice(i, i + 2);
            i += 2;
            continue;
        }
        if (ch !== "`") {
            out += ch;
            i++;
            continue;
        }
        // Code span: a run of N backticks closes on a run of exactly N.
        let runEnd = i + 1;
        while (runEnd < n && line[runEnd] === "`") runEnd++;
        const runLen = runEnd - i;
        let close = -1;
        for (let j = runEnd; j < n; j++) {
            if (line[j] !== "`") continue;
            let k = j + 1;
            while (k < n && line[k] === "`") k++;
            if (k - j === runLen) {
                close = j;
                break;
            }
            j = k - 1;
        }
        if (close === -1) {
            // Unclosed run renders literally; leave the rest of the line alone.
            out += line.slice(i);
            return out;
        }
        out += line.slice(i, runEnd);
        for (let k = runEnd; k < close; k++) {
            if (line[k] === "|" && line[k - 1] !== "\\") out += "\\";
            out += line[k];
        }
        out += line.slice(close, close + runLen);
        i = close + runLen;
    }
    return out;
}

/**
 * Returns the source with `\|` escapes added for pipes inside code spans on
 * table rows. Detection mirrors the block table rule: a header line
 * containing `|` followed by a delimiter row, then body rows until a blank
 * line or a block start that would terminate the table.
 */
export function escapeTableCodeSpanPipes(src: string): string {
    if (!src.includes("|") || !src.includes("`")) return src;
    const lines = src.split("\n");
    let fenceCh = "";
    let fenceLen = 0;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (fenceCh) {
            if (isFenceClose(line, fenceCh, fenceLen)) fenceCh = "";
            continue;
        }
        const fence = matchFenceOpen(line);
        if (fence) {
            fenceCh = fence.ch;
            fenceLen = fence.len;
            continue;
        }
        if (!line.includes("|") || INDENTED_CODE_RE.test(line)) continue;
        if (i + 1 >= lines.length || !isDelimiterRow(lines[i + 1])) continue;
        const inBlockquote = BLOCKQUOTE_PREFIX_RE.test(line);
        lines[i] = escapePipesInCodeSpans(line);
        let j = i + 2;
        for (; j < lines.length; j++) {
            const row = lines[j];
            if (isBlank(row) || INDENTED_CODE_RE.test(row) || matchFenceOpen(row)) {
                break;
            }
            const rowBq = BLOCKQUOTE_PREFIX_RE.test(row);
            // A blockquote boundary change ends the table; other terminator rules
            // only apply to top-level rows.
            if (rowBq !== inBlockquote) break;
            if (!rowBq && BODY_TERMINATOR_RES.some((re) => re.test(row))) break;
            lines[j] = escapePipesInCodeSpans(row);
        }
        i = j - 1;
    }
    return lines.join("\n");
}

/** Registers the preprocessing as a core rule running before block parsing. */
export function installTablePipeEscape(md: MarkdownIt): void {
    md.core.ruler.before("block", "table_pipe_escape", (state) => {
        // Same guard as the built-in normalize rule: non-string sources belong to
        // the streaming paths, which we don't use.
        if (typeof state.src !== "string") return;
        state.src = escapeTableCodeSpanPipes(state.src);
    });
}
