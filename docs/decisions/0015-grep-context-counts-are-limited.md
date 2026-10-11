# 0015 — The grep context counts are limited to 1000 lines per side

Date: 2026-10-11
Status: accepted

## Context

The context lines spec set no limit on the counts of lines before and
after a hit (ADR 0014). Its review measured what a large count of lines
before costs: `grep-searcher` keeps the last `before_context` lines of
its buffer on every refill, whether or not the file has a match. With a
count above a file's line count the buffer grows to hold the whole file,
per walker thread, and keeps that capacity until the search ends. A
216 MB file without a hit raised the peak memory by about 200 MB and the
time from 0.14 s to 0.65 s. A thread inside such a file also notices a
cancellation only when the file is done.

## Decision

A count is at most 1000 lines per side. The service enforces it: a
larger `:before` or `:after` is taken as 1000, without an error.
`quarry-grep.el` knows the same number (`quarry-grep-max-context`),
reduces a larger count before the search is built and says so in the
echo area, so the header line shows the count that is used.

The limit is a constant, not an option: it protects the module's memory,
and a context of more than 1000 lines is reading the file, for which
`RET` exists.

## Consequences

- The searcher holds at most 1000 lines of a file beyond its ordinary
  buffer, whatever is asked.
- The number exists twice, in `src/grep/service.rs` and in
  `lisp/quarry-grep.el`. They must be changed together; when they
  differ, the smaller one wins and the header line can show more than is
  delivered.
- The size of a result with context is still not capped (ADR 0014): at
  most `1 + before + after` times the hits.
