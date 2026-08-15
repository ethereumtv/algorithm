# Changelog

## v1.0 (2026-08-15)

First public release: the heuristic related-content model.

- Two-axis score `R * (1 + 0.6 * Q)`, relevance gating and a bounded quality
  prior refining the order within a tier.
- Relevance from shared subtopics (weighted above broad topics), shared
  contributor, shared network, same primary topic, same event, same format.
- Quality from resonance (Bayesian-smoothed like/view percentile), reach (log
  views), floored freshness, and a gem term that lifts under-viewed quality.
- Candidate generation bounded to the selective signals; broad signals applied
  as decorations only.
- No empty states: a resonance-ranked backfill pool tops up sparse items.
- Reference implementation as a single SQL function, plus a runnable example.

Planned: semantic similarity over transcript embeddings, folded into the
relevance component behind the same precomputed table.
