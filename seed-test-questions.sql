-- =============================================================================
-- SEED: add 10 sample questions to each grade (40 total)
-- =============================================================================
-- For testing the board with realistic-looking data — voting, rounds,
-- exclusions, archive, etc. Safe to run against your live project: it only
-- INSERTs into `questions`, using student IDs prefixed "TEST-" so they're
-- easy to spot and clean up later (see the DELETE at the very bottom).
--
-- Run in the Supabase SQL editor. Each block checks fn_check_admin isn't
-- needed here since this goes straight to the table, not through a
-- function — the SQL editor runs as the table owner already.
-- =============================================================================

insert into questions (grade, student_id, question) values
  -- ---------------------------- Grade 3 ----------------------------------
  ('3', 'TEST-301', 'Why is the sky blue?'),
  ('3', 'TEST-302', 'How do bees make honey?'),
  ('3', 'TEST-303', 'Why do we have to sleep?'),
  ('3', 'TEST-304', 'Can animals talk to each other?'),
  ('3', 'TEST-305', 'Why does the moon change shape?'),
  ('3', 'TEST-306', 'How do fish breathe underwater?'),
  ('3', 'TEST-307', 'Why do leaves change color in fall?'),
  ('3', 'TEST-308', 'What makes a rainbow appear?'),
  ('3', 'TEST-309', 'Why do we get hiccups?'),
  ('3', 'TEST-310', 'How do birds know where to fly?'),

  -- ---------------------------- Grade 4 ----------------------------------
  ('4', 'TEST-401', 'Why do volcanoes erupt?'),
  ('4', 'TEST-402', 'How do airplanes stay in the air?'),
  ('4', 'TEST-403', 'Why is the ocean salty?'),
  ('4', 'TEST-404', 'What causes earthquakes?'),
  ('4', 'TEST-405', 'How does the internet actually work?'),
  ('4', 'TEST-406', 'Why do we dream?'),
  ('4', 'TEST-407', 'How do plants know which way is up?'),
  ('4', 'TEST-408', 'Why does ice float on water?'),
  ('4', 'TEST-409', 'How do magnets work?'),
  ('4', 'TEST-410', 'Why do some animals hibernate?'),

  -- ---------------------------- Grade 5 ----------------------------------
  ('5', 'TEST-501', 'Could humans ever live on Mars?'),
  ('5', 'TEST-502', 'Why do we age?'),
  ('5', 'TEST-503', 'How do vaccines protect us?'),
  ('5', 'TEST-504', 'What would happen if the moon disappeared?'),
  ('5', 'TEST-505', 'How do computers understand code?'),
  ('5', 'TEST-506', 'Why do some species go extinct?'),
  ('5', 'TEST-507', 'How does memory work in the brain?'),
  ('5', 'TEST-508', 'Why is math the same all over the world?'),
  ('5', 'TEST-509', 'How do satellites stay in orbit?'),
  ('5', 'TEST-510', 'What causes optical illusions?'),

  -- ---------------------------- Grade 6 ----------------------------------
  ('6', 'TEST-601', 'Is time travel theoretically possible?'),
  ('6', 'TEST-602', 'How does artificial intelligence learn?'),
  ('6', 'TEST-603', 'What happens inside a black hole?'),
  ('6', 'TEST-604', 'Why do democracies sometimes disagree so much?'),
  ('6', 'TEST-605', 'How do vaccines get developed so quickly?'),
  ('6', 'TEST-606', 'Could we ever communicate with other planets?'),
  ('6', 'TEST-607', 'Why does music affect our emotions?'),
  ('6', 'TEST-608', 'How do scientists know how old the universe is?'),
  ('6', 'TEST-609', 'What makes something considered alive?'),
  ('6', 'TEST-610', 'Why do languages change over time?');

-- -----------------------------------------------------------------------
-- CLEANUP (optional): run this later to remove ONLY the test data above,
-- leaving any real student submissions untouched.
-- -----------------------------------------------------------------------
-- delete from questions where student_id like 'TEST-%';
