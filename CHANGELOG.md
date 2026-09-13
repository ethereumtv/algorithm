# Changelog

## v1.3 (2026-09-13)

- Sparse-item top-up raised from 6 to 13 rows. This supplies enough ranked,
  deduplicated candidates for a nine-item rail and an independently reserved
  four-item shelf, while the existing 16-row cap keeps deduplication headroom.
- Refresh guidance now recommends an independent schedule so an upstream
  statistics-sync failure cannot leave newly published items without rows.

## v1.2 (2026-08-31)

- Stored ranks per item raised from 12 to 16. Consumers that reserve a
  prefix of the ranking for one surface (Ethereum TV reserves ranks 1 to 9
  as the watch-page rail's fill pool) still have a genuine pool left for a
  second surface, such as a More-like-this shelf, after deduplicating
  against items already on screen. Scoring is unchanged.

## v1.1 (2026-08-30)

Mixing content types without letting one dominate. Ethereum TV added podcast
episodes next to conference talks; episodes carry 10 to 100 times the views of
a median talk, and a shared distribution would have turned the quality prior
into a content-type detector.

- Reach and resonance percentiles, and the like-rate smoothing prior C, are
  now computed within each item's content type.
- Per-type freshness and Q weights. The secondary type gets a short novelty
  spike (floor 0.25, tau 12 days) instead of the slow evergreen curve, and
  shifts 0.10 of Q weight from reach to freshness. After the spike fades,
  ordering within the type is carried by resonance and gem, so evergreen
  items surface through engagement with no editorial classification.
- On a primary-type anchor at most 2 secondary-type rows survive the ranking
  (kept by score); secondary-type anchors are uncapped.
- The no-empty-state fill pool is primary-type only.
- Ranking now orders by the unrounded numeric score; the real cast happens at
  storage time.
- `items.content_type` added to the example schema (default 'default'; a
  single-type catalog behaves exactly as v1.0).
- The full-table DELETE now reads `delete from related_items where true`:
  managed platforms that enforce a safe-update guard (Supabase invoking the
  refresh via PostgREST rpc, for instance) reject the unfiltered form, and
  the failure is silent from the caller's side. Identical semantics
  everywhere else.

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
