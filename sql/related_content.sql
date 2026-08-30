-- Ethereum TV Algorithm: related-content scoring.
--
-- One SQL function that precomputes, for every published item, an ordered set
-- of related items into `related_items`. Run it on a schedule (Ethereum TV
-- runs it every six hours, right after refreshing view and like counts).
--
-- The score has two axes that are kept deliberately separate:
--
--   Relevance R(A, B)  decides WHO is eligible to be shown next to item A.
--     4.0 * least(shared_subtopics, 3)   granular topic overlap dominates
--     1.5 * least(shared_top_topics, 2)  broad topic overlap, weak
--     3.0 * same_primary_topic
--     5.0 * shares_a_contributor         (speakers / authors; flat weight)
--     2.0 * shares_a_network             (ecosystem tag)
--     1.0 * same_event
--     0.5 * same_format
--
--   Quality Q(B) in [0, 1]  reorders the eligible set.
--     resonance  Bayesian-smoothed like/view percentile (m = 2000 pseudo-views
--                toward the per-type median rate C; hidden-like items sit at C)
--     reach      log-view percentile
--     freshness  floor + (1 - floor) * exp(-age_days / tau), per content type
--     gem        resonance * (1 - reach), lifts under-viewed quality
--     Q = w_resonance*resonance + w_reach*reach + w_freshness*freshness + w_gem*gem
--
--   score(A, B) = R(A, B) * (1 + 0.6 * Q(B))
--
-- Relevance leads; Q only refines the order within a relevance tier. If R is 0
-- the score is 0, so quality can never manufacture a relationship. See the
-- README for the full reasoning behind every weight.
--
-- MIXING CONTENT TYPES (v1.1). Catalogs that mix types with wildly different
-- audience sizes (conference talks next to podcast episodes) break a shared
-- distribution: the high-view type occupies the whole top of every percentile
-- and Q degrades into a content-type detector. So:
--   * reach, resonance, and the prior C are computed WITHIN each content type;
--   * freshness shape and Q weights are per type. The secondary type here
--     ('episode') gets a short novelty spike (floor 0.25, tau 12 days) and
--     shifts 0.10 of Q weight from reach to freshness, so timely content
--     surfaces while fresh and is then carried by resonance + gem alone;
--   * on a primary-type anchor at most `secondary_rail_cap` secondary-type
--     rows survive (admitted by score like everything else); the secondary
--     type's own anchors carry no cap.
-- With a single content type in the catalog all three changes are no-ops.
--
-- Candidate generation uses only the selective signals (shared subtopic,
-- contributor, network). Broad top-level topics, event, format, and the
-- primary-topic match are decorations on pairs that already exist, never
-- generators, so a hub topic on hundreds of items cannot explode the pair
-- space. No empty states: any item with fewer than six genuine matches is
-- topped up from a resonance-ranked global pool (primary-type items only, so
-- the serendipity slots keep the catalog's identity).
--
-- Portability note: this reference version is plain SECURITY INVOKER SQL so it
-- runs on any Postgres (see examples/). On a multi-tenant deployment such as
-- Supabase you would add SECURITY DEFINER, `set search_path = ''` with
-- schema-qualified objects, row-level security on `related_items`, and the
-- appropriate grants.

create table if not exists related_items (
  item_id uuid not null references items (id) on delete cascade,
  related_item_id uuid not null references items (id) on delete cascade,
  score real not null,
  rank smallint not null,
  primary key (item_id, related_item_id)
);

create index if not exists related_items_item_id_rank_idx
  on related_items (item_id, rank);

create or replace function refresh_related_items()
returns integer
language plpgsql
as $$
declare
  n integer;
  -- v1.1 tunables, declared once. 'default' covers every content type without
  -- its own row in the params CTE below.
  secondary_type constant text := 'episode';
  secondary_rail_cap constant integer := 2;
begin
  -- DELETE, not TRUNCATE, so concurrent readers keep MVCC visibility of the
  -- previous set through the whole recompute (never a briefly-empty result).
  -- The `where true` is deliberate: managed platforms (e.g. Supabase, when
  -- this runs via a PostgREST rpc) enforce a safe-update guard that rejects
  -- an unfiltered DELETE; this form satisfies it with identical semantics.
  delete from related_items where true;

  with params as (
    -- content_type, freshness floor, freshness tau (days), w_reach, w_freshness.
    -- w_resonance is 0.35 and w_gem 0.20 for every type.
    select * from (values
      ('default', 0.40, 540.0, 0.30, 0.15),
      ('episode', 0.25, 12.0, 0.20, 0.25)
    ) as v(content_type, fresh_floor, fresh_tau, w_reach, w_fresh)
  ),
  pub as (
    select
      i.id,
      coalesce(i.content_type, 'default') as content_type,
      coalesce(i.view_count, 0)::numeric as views,
      i.like_count as likes,
      coalesce(i.published_at, e.start_date) as eff_date,
      i.primary_topic_id,
      i.event_id,
      i.format_id
    from items i
    left join events e on e.id = i.event_id
    where i.published
  ),
  -- The like-rate smoothing prior C, per content type: distributions differ
  -- between types, and a shared median would shrink both toward the wrong
  -- center.
  consts as (
    select
      p.content_type,
      coalesce(
        percentile_cont(0.5) within group (
          order by (p.likes::numeric / nullif(p.views, 0))
        ) filter (where p.likes is not null and p.views > 0),
        0
      ) as c
    from pub p
    group by p.content_type
  ),
  qual as (
    select
      p.id,
      p.content_type,
      p.primary_topic_id,
      p.event_id,
      p.format_id,
      -- Percentiles WITHIN the row's content type (v1.1 core fix).
      percent_rank() over (
        partition by p.content_type order by ln(1 + p.views)
      ) as reach,
      percent_rank() over (
        partition by p.content_type
        order by (coalesce(p.likes, cn.c * p.views) + 2000 * cn.c) / (p.views + 2000)
      ) as resonance,
      pr.fresh_floor + (1 - pr.fresh_floor) * exp(
        -greatest(current_date - coalesce(p.eff_date, current_date - 3650), 0)
          / pr.fresh_tau
      ) as freshness,
      pr.w_reach,
      pr.w_fresh
    from pub p
    join consts cn on cn.content_type = p.content_type
    join params pr on pr.content_type = coalesce(
      (select p2.content_type from params p2 where p2.content_type = p.content_type),
      'default'
    )
  ),
  qfinal as (
    select
      id,
      content_type,
      primary_topic_id,
      event_id,
      format_id,
      resonance,
      (
        0.35 * resonance
        + w_reach * reach
        + w_fresh * freshness
        + 0.20 * (resonance * (1 - reach))
      )::numeric as qv
    from qual
  ),
  membership as (
    select distinct
      m.item_id,
      m.topic_id,
      (tp.parent_id is not null) as is_sub
    from (
      select item_id, topic_id from item_topics
      union
      select id as item_id, primary_topic_id as topic_id
      from items
      where primary_topic_id is not null
    ) m
    join items i on i.id = m.item_id and i.published
    join topics tp on tp.id = m.topic_id
  ),
  -- Generator: shared SUBTOPIC only (granular, modest fan-out).
  gen_subtopic as (
    select
      a.item_id as a_id,
      b.item_id as b_id,
      count(*) as shared_sub
    from membership a
    join membership b on a.topic_id = b.topic_id and a.item_id <> b.item_id
    where a.is_sub
    group by a.item_id, b.item_id
  ),
  gen_contributor as (
    select distinct a.item_id as a_id, b.item_id as b_id
    from item_contributors a
    join item_contributors b on a.contributor_id = b.contributor_id and a.item_id <> b.item_id
    join items ia on ia.id = a.item_id and ia.published
    join items ib on ib.id = b.item_id and ib.published
  ),
  gen_network as (
    select distinct a.item_id as a_id, b.item_id as b_id
    from item_networks a
    join item_networks b on a.network_id = b.network_id and a.item_id <> b.item_id
    join items ia on ia.id = a.item_id and ia.published
    join items ib on ib.id = b.item_id and ib.published
  ),
  candidates as (
    select a_id, b_id from gen_subtopic
    union
    select a_id, b_id from gen_contributor
    union
    select a_id, b_id from gen_network
  ),
  -- Decoration: shared TOP-LEVEL topics, counted only over existing candidate
  -- pairs, so the broad self-join is bounded by the candidate set.
  shared_top as (
    select c.a_id, c.b_id, count(*) as shared_top
    from candidates c
    join membership ma on ma.item_id = c.a_id and not ma.is_sub
    join membership mb on mb.item_id = c.b_id and not mb.is_sub and mb.topic_id = ma.topic_id
    group by c.a_id, c.b_id
  ),
  scored as (
    select
      c.a_id,
      c.b_id,
      coalesce(gt.shared_sub, 0) as shared_sub,
      coalesce(st.shared_top, 0) as shared_top,
      (gc.a_id is not null) as shares_contributor,
      (gn.a_id is not null) as shares_network,
      qa.content_type as a_type,
      qb.content_type as b_type,
      qa.primary_topic_id as a_primary,
      qb.primary_topic_id as b_primary,
      qa.event_id as a_event,
      qb.event_id as b_event,
      qa.format_id as a_format,
      qb.format_id as b_format,
      qb.qv as b_q
    from candidates c
    left join gen_subtopic gt on gt.a_id = c.a_id and gt.b_id = c.b_id
    left join shared_top st on st.a_id = c.a_id and st.b_id = c.b_id
    left join gen_contributor gc on gc.a_id = c.a_id and gc.b_id = c.b_id
    left join gen_network gn on gn.a_id = c.a_id and gn.b_id = c.b_id
    join qfinal qa on qa.id = c.a_id
    join qfinal qb on qb.id = c.b_id
  ),
  relevance as (
    select
      a_id,
      b_id,
      a_type,
      b_type,
      b_q,
      (
        4.0 * least(shared_sub, 3)
        + 1.5 * least(shared_top, 2)
        + case when a_primary is not null and a_primary = b_primary then 3.0 else 0 end
        + case when shares_contributor then 5.0 else 0 end
        + case when shares_network then 2.0 else 0 end
        + case when a_event is not null and a_event = b_event then 1.0 else 0 end
        + case when a_format is not null and a_format = b_format then 0.5 else 0 end
      ) as r
    from scored
  ),
  prelim as (
    select
      a_id,
      b_id,
      a_type,
      b_type,
      r * (1 + 0.6 * b_q) as score_num,
      -- Rank within (anchor, is-candidate-secondary) so the cap below keeps
      -- the BEST-scoring secondary-type rows, not arbitrary ones.
      row_number() over (
        partition by a_id, (b_type = secondary_type)
        order by r * (1 + 0.6 * b_q) desc, b_id
      ) as type_rank
    from relevance
    where r > 0
  ),
  -- v1.1 cap: on a primary-type anchor at most secondary_rail_cap
  -- secondary-type rows survive; a secondary-type anchor keeps its own kind
  -- uncapped.
  capped as (
    select a_id, b_id, score_num
    from prelim
    where a_type = secondary_type
      or b_type <> secondary_type
      or type_rank <= secondary_rail_cap
  ),
  ranked as (
    select
      a_id,
      b_id,
      score_num::real as score,
      row_number() over (
        partition by a_id
        order by score_num desc, b_id
      ) as rank
    from capped
  ),
  genuine as (
    select a_id, b_id, score, rank
    from ranked
    where rank <= 12
  ),
  -- No empty states: top up items with fewer than six genuine matches from a
  -- pool ranked by RESONANCE (the hidden-gem signal), not raw views, so even
  -- the tail surfaces quality rather than the same few most-viewed items.
  -- Primary-type items only (v1.1): the filler slots keep the catalog's
  -- identity.
  need as (
    select p.id as a_id, coalesce(g.cnt, 0) as have, coalesce(g.maxrank, 0) as maxrank
    from pub p
    left join (
      select a_id, count(*) as cnt, max(rank) as maxrank
      from genuine
      group by a_id
    ) g on g.a_id = p.id
    where coalesce(g.cnt, 0) < 6
  ),
  pool as (
    select id, qv, resonance
    from qfinal
    where content_type <> secondary_type
    order by resonance desc, qv desc, id
    limit 50
  ),
  fill_ranked as (
    select
      nd.a_id,
      pl.id as b_id,
      pl.qv::real as score,
      nd.maxrank,
      nd.have,
      row_number() over (partition by nd.a_id order by pl.resonance desc, pl.qv desc, pl.id) as frank
    from need nd
    join pool pl
      on pl.id <> nd.a_id
      and not exists (
        select 1 from genuine gg where gg.a_id = nd.a_id and gg.b_id = pl.id
      )
  ),
  fill as (
    select a_id, b_id, score, (maxrank + frank) as rank
    from fill_ranked
    where frank <= 6 - have
  ),
  combined as (
    select a_id, b_id, score, rank from genuine
    union all
    select a_id, b_id, score, rank from fill
  )
  insert into related_items (item_id, related_item_id, score, rank)
  select a_id, b_id, score, rank::smallint
  from combined;

  get diagnostics n = row_count;
  return n;
end;
$$;
