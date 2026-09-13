-- Executable regression checks for sparse top-up and dense truncation.
do $$
declare
  sparse_count integer;
  dense_count integer;
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
end;
$$;
