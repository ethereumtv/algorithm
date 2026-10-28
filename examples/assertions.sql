-- Executable regression checks. Run after refresh_related_items().
do $$
declare
  sparse_count integer;
  dense_count integer;
  host constant uuid := 'cccccccc-0000-0000-0000-000000000002';
begin
  select count(*) into sparse_count
  from related_items
  where item_id = 'ffffffff-0000-0000-0000-000000000001';

  if sparse_count <> 13 then
    raise exception 'sparse anchor expected 13 rows, found %', sparse_count;
  end if;

  select count(*) into dense_count
  from related_items
  where item_id = 'ffffffff-0000-0000-0000-000000000011';

  if dense_count <> 16 then
    raise exception 'dense anchor expected the 16-row cap, found %', dense_count;
  end if;

  if exists (
    select 1
    from related_items
    group by item_id
    having min(rank) <> 1
       or max(rank) <> count(*)
       or count(distinct rank) <> count(*)
       or count(distinct related_item_id) <> count(*)
       or max(rank) > 16
  ) then
    raise exception 'rank uniqueness, continuity, or cap invariant failed';
  end if;

  if exists (select 1 from related_items where item_id = related_item_id) then
    raise exception 'an anchor recommended itself';
  end if;

  if exists (select 1 from items i where i.published and
      (select count(*) from related_items r where r.item_id = i.id) < 13) then
    raise exception 'an item has fewer than 13 rows';
  end if;

  -- Top-up prefers context: p1's five genuine matches are followed by its
  -- only same-event sibling outside them, s11, before any global filler.
  if (select rank from related_items
      where item_id = 'ffffffff-0000-0000-0000-000000000001'
        and related_item_id = 'ffffffff-0000-0000-0000-000000000011') <> 6 then
    raise exception 'context top-up (same event) should follow the genuine rows';
  end if;

  -- Speaker spread: on every episode page the host holds at most 2 of the
  -- top 4 rows and at most 3 of the top 13.
  if exists (
    select 1
    from related_items r
    join item_contributors ca on ca.item_id = r.item_id and ca.contributor_id = host
    join item_contributors cb on cb.item_id = r.related_item_id and cb.contributor_id = host
    group by r.item_id
    having count(*) filter (where r.rank <= 4) > 2
        or count(*) filter (where r.rank <= 13) > 3
  ) then
    raise exception 'speaker spread failed: one contributor dominates an anchor';
  end if;

  -- Hub guard: the untagged episode shares only the hub host with the other
  -- episodes, so none of them is a match for it.
  if exists (
    select 1 from related_items r
    join items b on b.id = r.related_item_id
    where r.item_id = 'ffffffff-0000-0000-0002-000000000001'
      and b.content_type = 'episode'
  ) then
    raise exception 'hub guard failed: a shared hub contributor alone made a match';
  end if;

  -- The secondary-type cap: a talk page holds at most two episodes.
  if exists (
    select 1 from related_items r
    join items a on a.id = r.item_id and a.content_type <> 'episode'
    join items b on b.id = r.related_item_id and b.content_type = 'episode'
    group by r.item_id having count(*) > 2
  ) then
    raise exception 'episode cap failed on a talk page';
  end if;
end;
$$;
