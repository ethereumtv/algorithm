# Ethereum TV Algorithm

The recommendation algorithm behind [Ethereum TV](https://ethereumtv.co/), open sourced.

Every talk page on Ethereum TV shows a set of related talks. This repository is the scoring model that chooses and orders them: the reasoning behind it, the exact maths, and a reference implementation you can run and adapt. It is built for a searchable archive of conference talks, but the approach carries over to any catalog where items share structured signals (tags, authors, events) and carry engagement data (views, likes).

Version 1 is a transparent heuristic. It is a week of work rather than a research project, it runs as a single SQL function, and it can be upgraded to semantic similarity later without changing the interface.

## Why this exists

An archive lives or dies by whether a visitor who lands on one talk keeps watching. Good related links are the main lever for that. They also tell search engines how pages relate, which is the difference between a crawler seeing a pile of isolated videos and seeing a connected library.

The naive version of this is "show the most popular talks." It is easy and it is wrong. A handful of viral keynotes end up attached to every page, the archive feels shallow, and the genuinely relevant talk that happens to have modest view counts never gets surfaced. The whole point of a curated archive is to do better than a raw popularity sort.

So the design starts from two beliefs:

1. **Relevance decides who is eligible. Popularity only decides the order among the relevant.** A wildly popular but unrelated talk should never appear next to a talk it has nothing to do with.
2. **Quality is not the same as reach.** A talk with 3,000 views and a great like-to-view ratio is often a better recommendation than a talk with 30,000 views and a mediocre one. The engine should be able to find those, because that discovery is the value the platform adds.

## The model

For a talk `A`, every candidate talk `B` gets a score:

```
score(A, B) = R(A, B) * (1 + 0.6 * Q(B))
```

`R` is **relevance**: how related `B` is to `A`. `Q` is a bounded **quality prior** for `B`, independent of `A`. Relevance sets the scale and quality nudges the order within it. Because `Q` is in `[0, 1]`, quality can move a score by at most 60 percent, so a weakly related viral talk can never overtake a strongly related modest one. The multiplication also means that if `R` is zero, the score is zero: quality can never manufacture a relationship that is not there.

### Relevance: R

```
R(A, B) = 4.0 * min(shared_subtopics, 3)
        + 1.5 * min(shared_top_topics, 2)
        + 3.0 * same_primary_topic
        + 5.0 * shares_a_speaker
        + 2.0 * shares_a_network
        + 1.0 * same_event
        + 0.5 * same_format
```

The weights encode a few opinions worth stating plainly.

**Shared subtopics matter more than shared top-level topics.** Two talks both tagged with a granular subtopic, say "account abstraction" or "data availability sampling", are far more related than two talks that merely both sit under a broad heading like "scaling". Subtopic overlap is weighted higher, and the counts are capped (`min(..., 3)` and `min(..., 2)`) so that two shared subtopics is a strong signal while six is not meaningfully stronger, it usually just means both talks are broad.

**Sharing a speaker is a strong signal.** People follow speakers. It carries the highest single weight. It is flat: a speaker being the headline on both talks versus a supporting name on one does not change the weight, because in practice that distinction added noise, not signal.

**Sharing an ecosystem or network** (both about a given L2, both about zero knowledge) is a real relatedness axis in this domain and gets a moderate weight.

**Same event and same format are weak.** Being from the same conference or both being a workshop is a mild nudge, not a reason to be recommended on its own. The dedicated "from this event" and "from this speaker" views handle those cases directly, so here they only break ties.

### Quality: Q

`Q` blends four signals into a single number in `[0, 1]`. Each of the four is itself in `[0, 1]`.

```
Q(B) = 0.35 * resonance
     + 0.30 * reach
     + 0.15 * freshness
     + 0.20 * gem
```

**resonance** is the like-to-view ratio, expressed as a percentile rank across the catalog. This is the signal that rewards a talk for resonating with the people who watched it, regardless of how many that was. It is the hidden-gem lever.

Raw like-to-view ratios are treacherous at low view counts. A talk with 12 views and 5 likes has a ratio of 0.42, which is meaningless. So the ratio is smoothed toward the catalog median with a pseudo-count, a standard Bayesian shrinkage:

```
smoothed_like_rate(B) = (likes_B + m * C) / (views_B + m)
```

where `C` is the median like rate across all talks that have like data, and `m = 2000` is the smoothing strength in units of views. A talk needs real view volume before its own ratio outweighs the prior. YouTube omits the like count entirely for videos whose owner hid likes, so those talks are treated as having exactly the median rate rather than being punished with a zero.

`resonance` is then the percentile rank of `smoothed_like_rate` across the catalog.

**reach** is the popularity signal, `views` on a log scale, expressed as a percentile rank:

```
reach(B) = percentile_rank( ln(1 + views_B) )
```

The log matters. On a linear scale a single 400,000-view talk dwarfs everything and drags the ordering. On a log scale the difference between 4,000 and 40,000 views is treated as comparable to the difference between 40,000 and 400,000, which is how people actually perceive popularity.

**freshness** gives recent talks a bounded bonus without burying evergreen ones:

```
freshness(B) = 0.4 + 0.6 * exp( -age_in_days / 540 )
```

A brand new talk scores near 1.0. The value decays with a roughly eighteen-month time constant, but it never falls below a floor of 0.4. That floor is the "old but gold" protection: a five-year-old talk still keeps most of its standing and is carried by its resonance, rather than being pushed out of sight for the crime of being old.

**gem** is the discoverability term. It is high exactly when a talk has strong resonance and low reach:

```
gem(B) = resonance * (1 - reach)
```

This is a deliberate thumb on the scale for quality that has not yet found its audience. It is the mechanism that lets a brilliant, under-watched talk compete head to head with a polished popular one instead of always losing to view count.

A note on the weights: `gem` re-uses `resonance`, on purpose. Add the two terms and a high-resonance, low-reach talk carries an effective resonance weight near 0.55, while reach's marginal influence drops toward 0.10. That tilt toward quality over fame is the intended behavior of the whole system, not an accident of the arithmetic.

### Putting it together

Relevance is the primary axis and quality is the secondary one. Concretely, a candidate that shares a subtopic, a speaker, and the primary topic might have `R = 12`, while a candidate that only shares a broad top-level topic might have `R = 1.5`. No value of `Q`, which can lift a score by at most 60 percent, lets the second overtake the first. Within a tier of similarly relevant candidates, `Q` is what orders them, and there the resonance and gem terms make sure a quiet high-quality talk is not automatically beaten by a loud one.

The score is directional. `score(A, B)` uses `B`'s quality, because when we rank the talks shown next to `A`, what matters is how good each candidate `B` is. The reverse list, the talks shown next to `B`, is ranked by `A`'s quality. The relevance component is symmetric; only the quality prior differs by direction.

## How it is computed

The scores are precomputed into a table, refreshed on a schedule, and read as plain rows. Nothing is scored at request time.

**Candidate generation is deliberately narrow.** Comparing every talk against every other talk is quadratic and wasteful. Candidates are generated only from the selective signals: a shared subtopic, a shared speaker, or a shared network. These have modest fan-out. The broad signals, top-level topics and same-event and same-format, are never used to generate candidates, because a single popular topic attached to hundreds of talks would create hundreds of thousands of pairs on its own. Those broad signals are applied only as decorations on pairs that already exist for a better reason. This keeps the whole recompute cheap even as the catalog grows into the thousands.

**No empty states.** Every talk shows a related block, always. A talk with fewer than six genuine matches is topped up from a global pool. That pool is ranked by resonance, not by views, so even the filler tail surfaces quality rather than parading the same few popular talks onto every sparse page.

**Freshness of signals.** The recompute runs right after the periodic sync that refreshes view and like counts from YouTube, so relevance and the popularity signals never drift apart. On this catalog that is every six hours.

The reference function in [`sql/related_content.sql`](sql/related_content.sql) does all of this in one pass and writes the ordered results to a `related_content` table. See [`examples/TRYIT.md`](examples/TRYIT.md) to run it against a throwaway Postgres with synthetic data in about a minute.

## The data it expects

The engine needs, per item:

- a set of topic tags, where some tags are subtopics of others (a simple parent link is enough)
- a designated primary topic
- a set of contributors (speakers or authors)
- an optional grouping (an event or a collection) and an optional format
- an optional ecosystem or network tag
- a view count and, ideally, a like count
- a date

None of these are specific to video. Swap "speaker" for "author", "event" for "issue of a journal", "network" for "product line", and the same model ranks related articles or papers. The signals are the interface, not the domain.

## Limitations and what comes next

This is a heuristic, and it is honest about that.

It knows nothing about what a talk is actually about beyond its tags. Two talks can cover the same idea in different words and, if a curator tagged them differently, the engine will not connect them. The weights are hand-chosen and tuned against manual spot checks, not learned. At a small catalog some signals are near universal, for instance almost every talk shares the same top-level network, so they do little discriminating until the catalog diversifies.

The planned upgrade is semantic similarity over transcript embeddings, which addresses the "same idea, different words" gap directly. Because everything here sits behind a single precomputed table with a stable shape, that upgrade can land without touching the reading side or the interface. The heuristic and the semantic score can even run together, the heuristic as a fast, explainable baseline and the embedding score as a relevance signal folded into `R`.

## License

MIT. See [LICENSE](LICENSE). Use it, fork it, adapt it. If you build something with it we would love to hear about it.

## Contributing

Issues and pull requests are welcome, especially real-world reports of where the ranking felt wrong and why. The weights in particular are opinions, and better opinions backed by evidence are exactly the kind of contribution this repository is here to collect.
