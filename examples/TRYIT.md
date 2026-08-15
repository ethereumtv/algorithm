# Try it in about a minute

The algorithm is one SQL function over a handful of tables, so you can run the
whole thing against a throwaway Postgres and watch it rank a small synthetic
catalog. Nothing here is specific to Ethereum TV.

## Option A: you already have Postgres

From this directory, against any empty database:

```bash
psql "$DATABASE_URL" -f schema.sql
psql "$DATABASE_URL" -f ../sql/related_content.sql
psql "$DATABASE_URL" -f seed.sql
psql "$DATABASE_URL" -c "select refresh_related_items();"
```

## Option B: a disposable Postgres in Docker

```bash
docker run --rm -d --name algo-demo -e POSTGRES_HOST_AUTH_METHOD=trust -p 5599:5432 postgres:17
sleep 3
export PGURL="postgres://postgres@localhost:5599/postgres"
psql "$PGURL" -f schema.sql
psql "$PGURL" -f ../sql/related_content.sql
psql "$PGURL" -f seed.sql
psql "$PGURL" -c "select refresh_related_items();"
# ... inspect (below) ...
docker rm -f algo-demo   # tidy up when done
```

## What you should see

`refresh_related_items()` returns the number of rows written. Then look at the
related list for item `p1` (a privacy talk):

```sql
select right(related_item_id::text, 2) as item,
       round(score::numeric, 2) as score,
       rank,
       (select view_count from items i where i.id = r.related_item_id) as views,
       (select like_count from items i where i.id = r.related_item_id) as likes
from related_items r
where item_id = 'ffffffff-0000-0000-0000-000000000001'
order by rank;
```

```
 item | score | rank | views  | likes
------+-------+------+--------+-------
 02   | 17.72 |    1 | 300000 |   200
 03   | 13.27 |    2 |    800 |    60
 05   | 11.37 |    3 |     90 |    12
 06   | 10.97 |    4 |   5000 |
 04   | 10.02 |    5 |    150 |     2
 13   |  0.49 |    6 |     60 |     4
```

Two things are worth noticing, because they are the whole point of the design.

**The 90-view item beats the 5,000-view item.** Item `05` is the hidden gem:
only 90 views, but a strong like-to-view ratio. It ranks at position 3, above
item `06` with 5,000 views and above item `04` with 150 views. Popularity did
not win. Quality did.

**The 300,000-view item is not there because it is popular.** Item `02` is the
viral one, and it sits at position 1, but not for its view count. It shares a
contributor with `p1`, which is the single strongest relevance signal, so it
would rank near the top even with a fraction of the views. Strip that shared
contributor from `seed.sql` and it drops back into the pack.

Item `13` at the bottom, with a score under 1, is a filler: `p1` has only five
genuinely related items, so the sixth slot is topped up from the quality pool
to guarantee the block is never empty. See the README for how that pool is
chosen (by resonance, not by views).

Change the numbers in `seed.sql` and re-run `refresh_related_items()` to see
the ranking move.
