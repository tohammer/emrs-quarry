# 0014 — Grep context lines belong to kept lines and do not count for the cap

Date: 2026-10-11
Status: accepted

## Context

`grep-searcher` can report the lines before and after each match
(`before_context`, `after_context`, `Sink::context`). Its matches are
those of the primary filter only. The other line filters run in the
sink and drop some of these matches, so the searcher's idea of "around a
match" is wider than the result: it reports context for matches that are
never shown.

The line cap (`max-lines`) counts the lines of a result. With context a
result holds two kinds of lines, and the cap logic (a private count per
file, a shared counter, cutting a file's lines to what still fits) relies
on every line being a hit.

## Decision

Context is decided in the sink, relative to the lines that are kept: a
line is a context line when it lies within the requested distance of a
kept line and is not kept itself. The searcher is asked for the same
distances, which makes it report every line that can qualify; the sink
drops the rest. A match of the primary filter that another line filter
dropped is an ordinary line for this purpose and can be shown as context.
Line filters are not applied to context lines.

Context lines are not counted: not for `max-lines`, not in the summary's
`:lines`, not in the counts the buffer shows. The cap stays a cap on
hits.

## Consequences

- A result with context is at most `1 + before + after` times as large as
  the same result without. At the cap of 50,000 hits that can be several
  hundred thousand lines, and delivery and insertion grow with it
  (backlog, "Delivery of very large results is slower than the search").
  Accepted: context is switched on to read a small result closely.
- A line that an exclude line filter removed can still appear, in the
  context face, next to a hit. That is what the file contains there, and
  it is not counted or visited as a hit.
- The search stops at the hit that fills the cap. The last hit of a file
  can then come with its lines before and without its lines after.
- A search without context configures the searcher as before and costs
  what it did.
