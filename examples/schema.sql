-- Minimal schema the algorithm expects. Load this, then sql/related_content.sql,
-- then examples/seed.sql, then call refresh_related_items(). See TRYIT.md.
--
-- Everything is generic on purpose. Map your own catalog onto these tables:
--   items          the things you recommend (talks, articles, papers, ...)
--   topics         a tag taxonomy; a topic with a parent is a subtopic
--   item_topics    which items carry which topics (supporting tags)
--   contributors   speakers, authors, hosts
--   item_contributors
--   networks       ecosystems, product lines, or any coarse affinity tag
--   item_networks
--   events         an optional grouping with a date (a conference, an issue)

create table if not exists topics (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references topics (id)   -- non-null => this topic is a subtopic
);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  start_date date
);

create table if not exists items (
  id uuid primary key default gen_random_uuid(),
  published boolean not null default false,
  primary_topic_id uuid references topics (id),
  event_id uuid references events (id),
  format_id uuid,                 -- opaque: keynote, workshop, panel, ...
  view_count integer,
  like_count integer,             -- null when unknown or hidden
  published_at date
);

create table if not exists item_topics (
  item_id uuid not null references items (id) on delete cascade,
  topic_id uuid not null references topics (id) on delete cascade,
  primary key (item_id, topic_id)
);

create table if not exists item_contributors (
  item_id uuid not null references items (id) on delete cascade,
  contributor_id uuid not null,
  primary key (item_id, contributor_id)
);

create table if not exists item_networks (
  item_id uuid not null references items (id) on delete cascade,
  network_id uuid not null,
  primary key (item_id, network_id)
);

-- Reverse indexes for the self-joins in refresh_related_items().
create index if not exists item_topics_topic_idx on item_topics (topic_id);
create index if not exists item_contributors_contributor_idx on item_contributors (contributor_id);
create index if not exists item_networks_network_idx on item_networks (network_id);
create index if not exists items_primary_topic_idx on items (primary_topic_id);
create index if not exists items_event_idx on items (event_id);
