-- item_events.seq is a bigserial (phase1), which backs it with an implicit sequence. A
-- bigserial/identity column needs USAGE on that sequence granted separately from the table's
-- own insert grant -- the 2026-11-01 table-grants migration covered the table but missed this,
-- so inserts into item_events (e.g. via create_item, which runs security invoker as
-- `authenticated`) failed with "permission denied for sequence item_events_seq_seq".

grant usage on sequence public.item_events_seq_seq to authenticated;
