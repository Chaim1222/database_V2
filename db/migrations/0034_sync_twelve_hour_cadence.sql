-- 0034: user chose a 12-hour sync cadence; allow three hours of scheduling/retry slack.
-- The hourly health probe and the stuck-run threshold remain unchanged.
update ops.health_threshold set max_age = interval '15 hours' where kind = 'sync';
insert into ops.schema_migration (version) values ('0034') on conflict do nothing;
