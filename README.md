# Ethereum TV Algorithm

The recommendation algorithm behind [Ethereum TV](https://ethereumtv.co/), open sourced.

Every talk page on Ethereum TV shows a set of related talks. This repository is the scoring model that chooses and orders them: the reasoning behind it, the exact maths, and a reference implementation you can run and adapt. It is built for a searchable archive of conference talks, but the approach carries over to any catalog where items share structured signals (tags, authors, events) and carry engagement data (views, likes).

**Model, not plumbing.** The ranking rules here are the ones Ethereum TV runs in production, weight for weight. What is not here is the operational code around them: how Ethereum TV schedules the rebuild, splits it into small steps so the database stays responsive, and fills in new talks between rebuilds. The reference version does the same ranking in one function call.

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

**Same event and same format are weak.** Being from the same conference or both being a workshop is a mild nudge, not a reason to be recommended on its own. The dedicated "from this event" and "from this speaker" views handle those cases directly, so here they mostly break ties.

**The primary topic counts twice, and we know it.** Every talk's primary topic is also one of its topics. On Ethereum TV the primary topic is always a top-level heading, so two talks with the same primary topic also share a broad topic: 3.0 + 1.5 = 4.5, slightly more than one shared subtopic. If your catalog uses a subtopic as the primary topic, it counts as a shared subtopic instead. We are measuring whether to lower the primary weight; see [Limitations](#limitations-and-what-comes-next).

### Quality: Q

`Q` blends four signals into a single number in `[0, 1]`. Each of the four is itself in `[0, 1]`.

```
Q(B) = 0.35 * resonance
     + 0.30 * reach
     + 0.15 * freshness
     + 0.20 * gem
```

**resonance** is the like-to-view ratio, expressed as a percentile rank across the catalog (since v1.1, across the items of the same content type; see [Mixing content types](#mixing-content-types-v11)). This is the signal that rewards a talk for resonating with the people who watched it, regardless of how many that was. It is the hidden-gem lever.

Raw like-to-view ratios are treacherous at low view counts. A talk with 12 views and 5 likes has a ratio of 0.42, which is meaningless. So the ratio is smoothed toward the catalog median with a pseudo-count, a standard Bayesian shrinkage:

```
smoothed_like_rate(B) = (likes_B + m * C) / (views_B + m)
```

where `C` is the median like rate across all talks that have like data, and `m = 2000` is the smoothing strength in units of views. A talk needs real view volume before its own ratio outweighs the prior. YouTube omits the like count entirely for videos whose owner hid likes, so those talks are treated as having exactly the median rate rather than being punished with a zero.

`resonance` is then the percentile rank of `smoothed_like_rate` across the catalog.

**reach** is the popularity signal: where a talk's view count ranks among talks of the same type, as a percentile.

```
reach(B) = percentile_rank( views_B )
```

A rank is what keeps popularity in proportion. On a raw count a single 400,000-view talk would dwarf everything and drag the ordering. As a rank it is simply first in line, one step above the next talk, so no viral outlier can stretch the scale for the rest. Some talks come from a source with no view counter at all (a video hosted somewhere other than YouTube, say). An unknown count is not the same as nobody watching, so those talks get the middle value, 0.5, and the percentile is computed among the talks that do have a count.

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

Relevance is the primary axis and quality is the secondary one. Concretely, a candidate that shares a subtopic, a speaker, and the primary topic has at least `R = 12`. The weakest candidate the engine compares at all shares a single subtopic and nothing else, `R = 4`. Even a perfect `Q` lifts that to 6.4, so it can never overtake the first. Within a tier of similarly relevant candidates, `Q` is what orders them, and there the resonance and gem terms make sure a quiet high-quality talk is not automatically beaten by a loud one.

The score is directional. `score(A, B)` uses `B`'s quality, because when we rank the talks shown next to `A`, what matters is how good each candidate `B` is. The reverse list, the talks shown next to `B`, is ranked by `A`'s quality. The relevance component is symmetric; only the quality prior differs by direction.

### Mixing content types (v1.1)

Ethereum TV added podcast episodes next to conference talks, and that broke an assumption the maths had been quietly making: that every item in the catalog plays the same statistical game. A popular podcast episode carries 10 to 100 times the views of a median conference talk. Pour both into one distribution and the episodes occupy the entire top of the reach percentiles, every talk gets compressed toward the bottom, and the "quality" prior turns into a content-type detector. Three changes fix this, and together they are v1.1.

**Partition the statistics by content type.** `reach` and `resonance` become percentile ranks within the item's own content type, and the smoothing prior `C` is a per-type median. An episode's reach is its rank among episodes; a talk's is its rank among talks. `Q` stays comparable across types by construction, `gem` keeps working within each type, and no relevance weight changes. This is the core fix, and it is cheap: the window functions gain a `partition by content_type` and the median gains a `group by`.

**Per-type freshness, shaped to the content.** The value of podcast content is bimodal: news and commentary episodes matter for a week or two and little after, while a good interview is evergreen. No single decay curve expresses that, and classifying episodes editorially does not scale, because most shows publish both kinds. So episode freshness is a short novelty spike rather than a slower version of the talk curve:

```
talks:     0.40 + 0.60 * exp( -age_in_days / 540 )
episodes:  0.25 + 0.75 * exp( -age_in_days / 12 )
```

A new episode scores near 1.0, is at roughly 0.68 after a week and 0.31 after a month, and is close to the 0.25 floor within about six weeks. From then on the ordering among episodes is carried by resonance and gem, so evergreen episodes distinguish themselves through engagement rather than age, with no news-versus-evergreen flag anywhere in the system. Episode `Q` also shifts 0.10 of weight from reach to freshness (`0.35 resonance + 0.20 reach + 0.25 freshness + 0.20 gem`), which makes the spike bite while further muting raw view counts for the type that has too many of them.

**Cap the minority type on the majority's rails.** Even with honest statistics, a strongly related episode can earn a talk-page slot on merit, and it should. But a talk page whose rail is half podcast episodes stops feeling like an archive of talks. So on a talk anchor at most 2 of the stored related items are episodes, admitted by score like everything else; an episode's own rail carries no cap, because related episodes are expected there.

Some items should never appear in related lists at all. The reference function takes an `excluded_types` setting for them: those types are left out of scoring entirely, as anchors and as candidates. Ethereum TV excludes its community calls this way.

### Spreading speakers (v1.4)

A podcast host appears on every episode of their show, and a prolific speaker on dozens of talks. Left alone, sharing that one person can fill a whole list: on Ethereum TV, before v1.4, nearly half of all episode pages showed the same person on at least three of their four "More like this" cards. So at most 2 of the top 4 related items, and at most 3 of the top 13, may share any one speaker with the talk. Further items sharing that speaker are not dropped. They move down the list, behind the other related items and the top-up described below, so a long list still reaches them.

## How it is computed

The scores are precomputed into a table, refreshed on a schedule, and read as plain rows. Nothing is scored at request time.

**Candidate generation is deliberately narrow.** Comparing every talk against every other talk is quadratic and wasteful. Two talks are compared only when they share a subtopic or a speaker. Everything else in `R` is a bonus that applies only to pairs that already exist for one of those reasons: top-level topics, the primary topic, same event, same format, and, since v1.4, networks. A tag carried by most of the catalog (on Ethereum TV, the single "Ethereum" network tag produced over a fifth of all compared pairs) would otherwise connect everything to everything and teach the engine nothing. For the same reason a speaker who appears on more than 100 items, in practice a podcast host, adds the speaker bonus but does not make two items a pair on their own. This keeps the whole recompute cheap even as the catalog grows into the tens of thousands.

**No empty states.** Every talk shows related recommendations, always. A talk with fewer than thirteen genuine matches is topped up in two tiers:

1. **Context first.** Well-received items from the talk's own event (unless the event is a catch-all grouping rather than a real event) and from each of its top-level topics, the top 40 of each by `Q`, of the same content type. They are scored with the same formula; only the bonus signals can apply, because a shared subtopic or speaker would already have made them a match. A talk on the same subject therefore ranks above one that only shares the conference.
2. **Then the archive's best.** The top 100 talks by `Q`, in an order that is fixed for each page but different from page to page. Before v1.4 this tier was a single sorted list, so a handful of talks sat on thousands of pages; a per-page order spreads them out while staying well-received.

Thirteen gives a multi-surface consumer enough rows for a nine-item rail and a separately reserved four-item shelf; the stored cap of sixteen leaves some deduplication headroom.

**Freshness of signals.** Recompute the ranking on its own schedule, and refresh it after the periodic sync that updates view and like counts when practical. Keeping an independent refresh prevents a failed upstream statistics sync from leaving newly published items without recommendations. Ethereum TV marks the ranking dirty on catalog changes and checks that state every five minutes, so publication does not wait for a full rebuild and new items receive rows promptly. That scheduling code is part of Ethereum TV's own database, not this repository.

The reference function in [`sql/related_content.sql`](sql/related_content.sql) does all of this in one pass and writes the ordered results to a `related_items` table. See [`examples/TRYIT.md`](examples/TRYIT.md) to run it against a throwaway Postgres with synthetic data in about a minute.

## The data it expects

The engine needs, per item:

- a set of topic tags, where some tags are subtopics of others (a simple parent link is enough)
- a designated primary topic
- a set of contributors (speakers, authors or hosts)
- an optional grouping (an event or a collection), marked when it is a catch-all bucket rather than a real event, and an optional format
- an optional ecosystem or network tag
- a view count when the source has one and, ideally, a like count
- a date
- a content type, when the catalog mixes kinds of item

None of these are specific to video. Swap "speaker" for "author", "event" for "issue of a journal", "network" for "product line", and the same model ranks related articles or papers. The signals are the interface, not the domain.

## Limitations and what comes next

This is a heuristic, and it is honest about that.

It knows nothing about what a talk is actually about beyond its tags. Two talks can cover the same idea in different words and, if a curator tagged them differently, the engine will not connect them. A talk with no tags at all can only be matched through its speakers, and is otherwise topped up from its event and the archive's best. The weights are hand-chosen and tuned against manual spot checks, not learned. Whether the primary topic should count for less than it does is an open question we are measuring on real pages before changing it.

The planned upgrade is semantic similarity over transcript embeddings, which addresses the "same idea, different words" gap directly. Because everything here sits behind a single precomputed table with a stable shape, that upgrade can land without touching the reading side or the interface. The heuristic and the semantic score can even run together, the heuristic as a fast, explainable baseline and the embedding score as a relevance signal folded into `R`.

## License

MIT. See [LICENSE](LICENSE). Use it, fork it, adapt it. If you build something with it we would love to hear about it.

## Contributing

Issues and pull requests are welcome, especially real-world reports of where the ranking felt wrong and why. The weights in particular are opinions, and better opinions backed by evidence are exactly the kind of contribution this repository is here to collect.
