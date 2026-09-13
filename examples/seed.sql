-- Synthetic catalog: 6 privacy items and 18 scaling items, plus one shared
-- contributor, one cross-topic shared network, and a couple of shared events.
-- Two items are engineered to show the quality axis at work:
--   p2  a "viral" item: huge views, weak like rate
--   p5  a "hidden gem": tiny views, strong like rate
-- After refresh, p5 should hold its own against p2 among privacy peers, and
-- neither should dominate on views alone.

-- Topics: two top-level headings, each with one subtopic.
insert into topics (id, parent_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001', null),                                   -- Privacy (top level)
  ('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000001'), -- zk-proofs (subtopic)
  ('aaaaaaaa-0000-0000-0000-000000000003', null),                                   -- Scaling (top level)
  ('aaaaaaaa-0000-0000-0000-000000000004', 'aaaaaaaa-0000-0000-0000-000000000003'); -- rollups (subtopic)

insert into events (id, start_date) values
  ('eeeeeeee-0000-0000-0000-000000000001', date '2023-05-01');

-- Items. primary_topic is the subtopic; views/likes vary to move reach/resonance.
insert into items (id, published, primary_topic_id, event_id, view_count, like_count, published_at) values
  ('ffffffff-0000-0000-0000-000000000001', true, 'aaaaaaaa-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001',   1200,   40, date '2023-05-02'),
  ('ffffffff-0000-0000-0000-000000000002', true, 'aaaaaaaa-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001', 300000,  200, date '2023-05-02'), -- viral, weak like rate
  ('ffffffff-0000-0000-0000-000000000003', true, 'aaaaaaaa-0000-0000-0000-000000000002', 'eeeeeeee-0000-0000-0000-000000000001',    800,   60, date '2022-09-10'),
  ('ffffffff-0000-0000-0000-000000000004', true, 'aaaaaaaa-0000-0000-0000-000000000002', null,                                     150,    2, date '2021-03-01'),
  ('ffffffff-0000-0000-0000-000000000005', true, 'aaaaaaaa-0000-0000-0000-000000000002', null,                                      90,   12, date '2019-06-15'), -- hidden gem
  ('ffffffff-0000-0000-0000-000000000006', true, 'aaaaaaaa-0000-0000-0000-000000000002', null,                                    5000, null, date '2024-01-20'), -- likes hidden
  ('ffffffff-0000-0000-0000-000000000011', true, 'aaaaaaaa-0000-0000-0000-000000000004', 'eeeeeeee-0000-0000-0000-000000000001',   2000,   50, date '2023-05-03'),
  ('ffffffff-0000-0000-0000-000000000012', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                     400,    5, date '2022-02-11'),
  ('ffffffff-0000-0000-0000-000000000013', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                      60,    4, date '2020-10-05'),
  ('ffffffff-0000-0000-0000-000000000014', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    9000,  300, date '2025-01-08'),
  ('ffffffff-0000-0000-0000-000000000015', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    1200,   30, date '2024-02-01'),
  ('ffffffff-0000-0000-0000-000000000016', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    1500,   35, date '2024-03-01'),
  ('ffffffff-0000-0000-0000-000000000017', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    1800,   42, date '2024-04-01'),
  ('ffffffff-0000-0000-0000-000000000018', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    2100,   48, date '2024-05-01'),
  ('ffffffff-0000-0000-0000-000000000019', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    2400,   55, date '2024-06-01'),
  ('ffffffff-0000-0000-0000-000000000020', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    2700,   61, date '2024-07-01'),
  ('ffffffff-0000-0000-0000-000000000021', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    3000,   68, date '2024-08-01'),
  ('ffffffff-0000-0000-0000-000000000022', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    3300,   74, date '2024-09-01'),
  ('ffffffff-0000-0000-0000-000000000023', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    3600,   81, date '2024-10-01'),
  ('ffffffff-0000-0000-0000-000000000024', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    3900,   87, date '2024-11-01'),
  ('ffffffff-0000-0000-0000-000000000025', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    4200,   94, date '2024-12-01'),
  ('ffffffff-0000-0000-0000-000000000026', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    4500,  100, date '2025-01-01'),
  ('ffffffff-0000-0000-0000-000000000027', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    4800,  107, date '2025-02-01'),
  ('ffffffff-0000-0000-0000-000000000028', true, 'aaaaaaaa-0000-0000-0000-000000000004', null,                                    5100,  113, date '2025-03-01');

-- Supporting tags: every item also carries its top-level heading, so two items
-- in the same area share both a subtopic (strong) and a top-level topic (weak).
insert into item_topics (item_id, topic_id)
select id, 'aaaaaaaa-0000-0000-0000-000000000002'::uuid from items where primary_topic_id = 'aaaaaaaa-0000-0000-0000-000000000002'
union all
select id, 'aaaaaaaa-0000-0000-0000-000000000001'::uuid from items where primary_topic_id = 'aaaaaaaa-0000-0000-0000-000000000002'
union all
select id, 'aaaaaaaa-0000-0000-0000-000000000004'::uuid from items where primary_topic_id = 'aaaaaaaa-0000-0000-0000-000000000004'
union all
select id, 'aaaaaaaa-0000-0000-0000-000000000003'::uuid from items where primary_topic_id = 'aaaaaaaa-0000-0000-0000-000000000004';

-- One shared contributor across p1 and p2 (the strongest single signal).
insert into item_contributors (item_id, contributor_id) values
  ('ffffffff-0000-0000-0000-000000000001', 'cccccccc-0000-0000-0000-000000000001'),
  ('ffffffff-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000001');

-- One shared network links a privacy item and a scaling item across topics,
-- so ecosystem affinity alone can make a (weak) related pair.
insert into item_networks (item_id, network_id) values
  ('ffffffff-0000-0000-0000-000000000003', 'dddddddd-0000-0000-0000-000000000001'),
  ('ffffffff-0000-0000-0000-000000000011', 'dddddddd-0000-0000-0000-000000000001');
