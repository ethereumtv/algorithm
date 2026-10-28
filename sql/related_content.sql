-- Ethereum TV Algorithm: related-content scoring, v1.4.
--
-- One SQL function that precomputes, for every published item, an ordered set
-- of related items into `related_items`. Run it on a schedule. These are the
-- same ranking rules Ethereum TV runs in production; only the plumbing
-- differs (production pages the same work through small scheduled steps).
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
--     reach      percentile rank of views among items of the same type that
--                have a view count; an unknown count is 0.5
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
-- WHO GETS COMPARED. Only a shared subtopic or a shared contributor makes two
-- items candidates. A contributor on more than `hub_min_items` items (a
-- podcast host, say) and every network only add their bonus to pairs that
-- exist for another reason, so one tag cannot link the whole catalog. Broad
-- top-level topics, primary topic, event and format are bonuses too.
--
-- MIXING CONTENT TYPES (v1.1). Catalogs that mix types with wildly different
-- audience sizes (conference talks next to podcast episodes) break a shared
-- distribution. So reach, resonance and the prior C are computed within each
-- content type; freshness shape and Q weights are per type (the secondary
-- type 'episode' gets a short novelty spike); and on a primary-type anchor at
-- most `secondary_rail_cap` secondary-type rows survive. Types listed in
-- `excluded_types` are left out entirely, as anchors and as candidates.
--
-- SPEAKER SPREAD (v1.4). At most 2 of the top 4 rows and 3 of the top 13 may
-- share any one contributor with the anchor. Further rows sharing that
-- contributor move down the list, not out.
--
-- NO EMPTY STATES (v1.4). An item short of 13 rows is filled first from its
-- context: the top `context_pool_size` items of its own type by Q from its
-- event (unless the event is a catch-all grouping) and from each of its
-- top-level topics, scored with the same formula (only the bonus signals can
-- apply, or the pair would have been a candidate). Then from the top
-- `global_pool_size` primary-type items by Q, in an order that is stable for
-- each anchor but differs between anchors, so no single item tops every
-- sparse page. At most 16 rows are stored per item.
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
  -- Tunables, declared once. 'default' covers every content type without its
  -- own row in the params CTE below.
  secondary_type constant text := 'episode';
  secondary_rail_cap constant integer := 2;
  excluded_types constant text[] := '{}';  -- Ethereum TV: '{call}'
  hub_min_items constant integer := 100;
  context_pool_size constant integer := 40;
  global_pool_size constant integer := 100;
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
      -- null: no view count (the source has no counter), which is unknown,
      -- not unwatched.
      i.view_count::numeric as views,
      i.like_count as likes,
      coalesce(i.published_at, e.start_date) as eff_date,
      i.primary_topic_id,
      i.event_id,
      case when not coalesce(e.is_catch_all, false) then i.event_id end as context_event_id,
      i.format_id
    from items i
    left join events e on e.id = i.event_id
    where i.published
      and not (coalesce(i.content_type, 'default') = any(excluded_types))
  ),
  -- The like-rate smoothing prior C, per content type.
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
      p.context_event_id,
      p.format_id,
      -- Percentiles WITHIN the row's content type (v1.1).
      case
        when p.views is null then 0.5
        else percent_rank() over (
          partition by p.content_type, (p.views is null) order by p.views
        )
      end as reach,
      percent_rank() over (
        partition by p.content_type
        order by case
          when p.views is null then cn.c
          else (coalesce(p.likes, cn.c * p.views) + 2000 * cn.c) / (p.views + 2000)
        end
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
  qfinal as materialized (
    select
      id,
      content_type,
      primary_topic_id,
      event_id,
      context_event_id,
      format_id,
      (
        0.35 * resonance
        + w_reach * reach
        + w_fresh * freshness
        + 0.20 * (resonance * (1 - reach))
      )::numeric as qv
    from qual
  ),
  membership as materialized (
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
    join qfinal q on q.id = m.item_id
    join topics tp on tp.id = m.topic_id
  ),
  topic_sets as materialized (
    select item_id, array_agg(topic_id) filter (where not is_sub) as top_ids
    from membership
    group by item_id
  ),
  contributors as materialized (
    select ic.item_id, ic.contributor_id
    from item_contributors ic
    join qfinal q on q.id = ic.item_id
  ),
  networks as materialized (
    select n.item_id, n.network_id
    from item_networks n
    join qfinal q on q.id = n.item_id
  ),
  hubs as materialized (
    select contributor_id from contributors
    group by contributor_id having count(*) > hub_min_items
  ),
  -- Fill pools. tier 1: an event's top items by Q per type; tier 2: a
  -- top-level topic's top items by Q per type; tier 3: the top primary-type
  -- items by Q.
  pool as materialized (
    select 1 as tier, x.context_event_id as key, x.content_type, x.id, x.qv from (
      select q.context_event_id, q.content_type, q.id, q.qv,
        row_number() over (
          partition by q.context_event_id, q.content_type order by q.qv desc, q.id
        ) as r
      from qfinal q
      where q.context_event_id is not null
    ) x where x.r <= context_pool_size
    union all
    select 2, x.topic_id, x.content_type, x.id, x.qv from (
      select m.topic_id, q.content_type, q.id, q.qv,
        row_number() over (
          partition by m.topic_id, q.content_type order by q.qv desc, q.id
        ) as r
      from membership m
      join qfinal q on q.id = m.item_id
      where not m.is_sub
    ) x where x.r <= context_pool_size
    union all
    select 3, null, x.content_type, x.id, x.qv from (
      select q.content_type, q.id, q.qv,
        row_number() over (order by q.qv desc, q.id) as r
      from qfinal q
      where q.content_type <> secondary_type
    ) x where x.r <= global_pool_size
  ),
  -- Generator: shared SUBTOPIC (granular, modest fan-out).
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
  -- Generator: shared CONTRIBUTOR, unless the contributor is a hub.
  gen_contributor as (
    select distinct a.item_id as a_id, b.item_id as b_id
    from contributors a
    join contributors b on a.contributor_id = b.contributor_id and a.item_id <> b.item_id
    where a.contributor_id not in (select contributor_id from hubs)
  ),
  candidates as (
    select a_id, b_id, max(shared_sub) as shared_sub,
      bool_or(shares_contributor) as shares_contributor
    from (
      select a_id, b_id, shared_sub, false as shares_contributor from gen_subtopic
      union all
      select a_id, b_id, 0::bigint, true from gen_contributor
    ) edges
    group by a_id, b_id
  ),
  scored as (
    select
      c.a_id,
      c.b_id,
      c.shared_sub,
      -- Decorations, counted only over existing candidate pairs, so the broad
      -- signals never meet the whole catalog.
      coalesce((select count(*) from unnest(ma.top_ids) as topic_id
        where topic_id = any(mb.top_ids)), 0) as shared_top,
      c.shares_contributor or exists (
        select 1 from contributors ca
        join contributors cb on cb.contributor_id = ca.contributor_id and cb.item_id = c.b_id
        where ca.item_id = c.a_id
      ) as shares_contributor,
      exists (
        select 1 from networks na
        join networks nb on nb.network_id = na.network_id and nb.item_id = c.b_id
        where na.item_id = c.a_id
      ) as shares_network,
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
    left join topic_sets ma on ma.item_id = c.a_id
    left join topic_sets mb on mb.item_id = c.b_id
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
      shares_contributor,
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
      shares_contributor,
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
  capped as materialized (
    select a_id, b_id, shares_contributor, score_num
    from prelim
    where a_type = secondary_type
      or b_type <> secondary_type
      or type_rank <= secondary_rail_cap
  ),
  -- v1.4 contributor spread. One row per (anchor, related, shared contributor),
  -- with k the row's place by score among the anchor's rows sharing that
  -- contributor. A row's k is its worst place over its shared contributors.
  spread_rows as materialized (
    select c.a_id, c.b_id, ca.contributor_id,
      row_number() over (
        partition by c.a_id, ca.contributor_id order by c.score_num desc, c.b_id
      ) as k
    from capped c
    join contributors ca on ca.item_id = c.a_id
    join contributors cb
      on cb.item_id = c.b_id and cb.contributor_id = ca.contributor_id
    where c.shares_contributor
  ),
  genuine as materialized (
    select c.a_id, c.b_id, c.score_num, coalesce(s.k, 0) as k
    from capped c
    left join (
      select a_id, b_id, max(k) as k from spread_rows group by a_id, b_id
    ) s on s.a_id = c.a_id and s.b_id = c.b_id
  ),
  -- The bands below can only ever use a genuine row among the best 16
  -- with k <= 2, the best 12 with k = 3 or the best 3 with k >= 4, so
  -- they read at most 31 genuine rows per anchor.
  shortlist as materialized (
    select a_id, b_id, score_num, k from (
      select a_id, b_id, score_num, k,
        row_number() over (
          partition by a_id, case when k <= 2 then 0 when k = 3 then 1 else 2 end
          order by score_num desc, b_id
        ) as class_pos
      from genuine
    ) x
    where (k <= 2 and class_pos <= 16) or (k = 3 and class_pos <= 12)
      or (k >= 4 and class_pos <= 3)
  ),
  -- Ranks 1 to 4 take rows with k <= 2 and ranks 5 to 13 rows with
  -- k <= 3. An anchor needs fill when its genuine rows cannot fill both.
  need as materialized (
    select q.id as a_id, q.content_type, q.primary_topic_id, q.event_id,
      q.context_event_id, q.format_id
    from qfinal q
    left join (
      select a_id, count(*) filter (where k <= 2) as k2,
        count(*) filter (where k <= 3) as k3
      from shortlist group by a_id
    ) c on c.a_id = q.id
    where coalesce(c.k2, 0) < 4
      or coalesce(c.k3, 0) - least(coalesce(c.k2, 0), 4) < 9
  ),
  -- Fill pairs: tier 1 context (event, top-level topics), tier 2 global.
  -- An anchor's genuine rows enter as tier 0 so the distinct below drops
  -- them from fill without an anti-join against every candidate.
  fill_pairs as (
    select distinct on (a_id, b_id) a_id, b_id, tier
    from (
      select g.a_id, g.b_id, 0 as tier
      from genuine g join need n on n.a_id = g.a_id
      union all
      select n.a_id, p.id, 1
      from need n
      join pool p
        on p.tier = 1 and p.key = n.context_event_id and p.content_type = n.content_type
      union all
      select n.a_id, p.id, 1
      from need n
      join topic_sets ts on ts.item_id = n.a_id
      cross join unnest(ts.top_ids) as top(topic_id)
      join pool p
        on p.tier = 2 and p.key = top.topic_id and p.content_type = n.content_type
      union all
      select n.a_id, p.id, 2
      from need n
      join pool p on p.tier = 3
    ) pairs
    where b_id <> a_id
    order by a_id, b_id, tier
  ),
  -- Context rows use the same R as genuine rows. A shared subtopic or a
  -- shared non-hub contributor would have made the pair genuine, so only the
  -- bonus signals can apply here (a hub contributor's +5 included).
  context_scored as (
    select x.a_id, x.b_id,
      (
        1.5 * least(
          coalesce((select count(*) from unnest(ma.top_ids) as topic_id
            where topic_id = any(mb.top_ids)), 0), 2)
        + case when n.primary_topic_id is not null and n.primary_topic_id = qb.primary_topic_id then 3.0 else 0 end
        + case when exists (
            select 1
            from contributors ca
            join contributors cb
              on cb.contributor_id = ca.contributor_id and cb.item_id = x.b_id
            where ca.item_id = x.a_id
          ) then 5.0 else 0 end
        + case when exists (
            select 1
            from networks na
            join networks nb
              on nb.network_id = na.network_id and nb.item_id = x.b_id
            where na.item_id = x.a_id
          ) then 2.0 else 0 end
        + case when n.event_id is not null and n.event_id = qb.event_id then 1.0 else 0 end
        + case when n.format_id is not null and n.format_id = qb.format_id then 0.5 else 0 end
      ) * (1 + 0.6 * qb.qv) as score_num
    from fill_pairs x
    join need n on n.a_id = x.a_id
    join qfinal qb on qb.id = x.b_id
    left join topic_sets ma on ma.item_id = x.a_id
    left join topic_sets mb on mb.item_id = x.b_id
    where x.tier = 1
  ),
  -- Context by score; the global tier in a per-page order (md5 of the
  -- pair), so no single talk tops every sparse page.
  fill_ranked as materialized (
    select f.a_id, f.b_id, f.score_num,
      row_number() over (
        partition by f.a_id
        order by f.tier,
          case when f.tier = 1 then f.score_num else 0 end desc,
          md5(f.a_id::text || f.b_id::text)
      ) as fpos
    from (
      select a_id, b_id, score_num, 1 as tier from context_scored
      union all
      select x.a_id, x.b_id, qb.qv, 2
      from fill_pairs x
      join qfinal qb on qb.id = x.b_id
      where x.tier = 2
    ) f
  ),
  -- Spread covers fill too: a fill row's place among the rows sharing a
  -- contributor continues after every genuine row sharing that contributor.
  fill_k as (
    select x.a_id, x.b_id, max(x.k) as k
    from (
      select f.a_id, f.b_id,
        coalesce(gc.n, 0) + row_number() over (
          partition by f.a_id, ca.contributor_id order by f.fpos
        ) as k
      from fill_ranked f
      join contributors ca on ca.item_id = f.a_id
      join contributors cb
        on cb.item_id = f.b_id and cb.contributor_id = ca.contributor_id
      left join (
        select a_id, contributor_id, count(*) as n from spread_rows group by a_id, contributor_id
      ) gc on gc.a_id = f.a_id and gc.contributor_id = ca.contributor_id
    ) x
    group by x.a_id, x.b_id
  ),
  -- Every row an anchor may place: genuine rows by score, then fill.
  ordered as materialized (
    select a_id, b_id, score_num, false as filled, k, 0 as src,
      row_number() over (partition by a_id order by score_num desc, b_id) as seq
    from shortlist
    union all
    select f.a_id, f.b_id, f.score_num, true, coalesce(fk.k, 0), 1, f.fpos
    from fill_ranked f
    left join fill_k fk on fk.a_id = f.a_id and fk.b_id = f.b_id
  ),
  band_a as materialized (
    select a_id, b_id from (
      select a_id, b_id, row_number() over (partition by a_id order by src, seq) as pos
      from ordered where k <= 2
    ) x where pos <= 4
  ),
  band_b as materialized (
    select a_id, b_id from (
      select o.a_id, o.b_id, row_number() over (partition by o.a_id order by o.src, o.seq) as pos
      from ordered o
      where o.k <= 3
        and not exists (select 1 from band_a x where x.a_id = o.a_id and x.b_id = o.b_id)
    ) y where pos <= 9
  ),
  -- Ranks 14 to 16: the best remaining genuine rows (fill tops up to 13 only).
  band_c as (
    select a_id, b_id from (
      select o.a_id, o.b_id, row_number() over (partition by o.a_id order by o.src, o.seq) as pos
      from ordered o
      where o.src = 0
        and not exists (select 1 from band_a x where x.a_id = o.a_id and x.b_id = o.b_id)
        and not exists (select 1 from band_b x where x.a_id = o.a_id and x.b_id = o.b_id)
    ) z where pos <= 3
  ),
  ranked as (
    select o.a_id, o.b_id, o.score_num, o.filled,
      row_number() over (partition by o.a_id order by p.band, o.src, o.seq) as rank
    from (
      select a_id, b_id, 1 as band from band_a
      union all select a_id, b_id, 2 from band_b
      union all select a_id, b_id, 3 from band_c
    ) p
    join ordered o on o.a_id = p.a_id and o.b_id = p.b_id
  )
  insert into related_items (item_id, related_item_id, score, rank)
  select a_id, b_id, score_num::real, rank::smallint
  from ranked
  where rank <= 16;

  get diagnostics n = row_count;
  return n;
end;
$$;
