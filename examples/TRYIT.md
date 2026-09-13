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
psql "$DATABASE_URL" -f assertions.sql
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
psql "$PGURL" -f assertions.sql
# ... inspect (below) ...
docker rm -f algo-demo   # tidy up when done
```

## What you should see

`refresh_related_items()` returns the number of rows written, and
`assertions.sql` completes without an exception. The assertions prove that a
sparse anchor reaches 13 rows, a dense anchor stops at 16, ranks are contiguous
and unique, and no item recommends itself. Then inspect the related list for
item `p1` (a privacy talk):

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

Ranks 6 through 13 are fillers: `p1` has only five genuinely related items, so
later slots are topped up from the quality pool to guarantee enough rows for
consuming surfaces. See the README for how that pool is chosen (by resonance,
not by views).

Change the numbers in `seed.sql` and re-run `refresh_related_items()` to see
the ranking move.
