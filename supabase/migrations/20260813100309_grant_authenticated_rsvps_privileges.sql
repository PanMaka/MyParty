-- rsvps (20260813095416_rsvps.sql) enabled RLS and added policies but,
-- same oversight as 20260812115436_grant_authenticated_table_privileges.sql,
-- never granted the underlying table privileges the policies assume.
-- All four rsvps policies are `to authenticated`.

grant select, insert, update, delete on public.rsvps to authenticated;
