-- Proves 20261004234903_explicit_grants_only.sql: anon and authenticated hold
-- exactly the grants some migration names, and nothing the image's default
-- privileges hand out.
--
-- The allow-list below is the WHOLE grant surface of public for the two client
-- roles -- table, column, sequence and function. It is compared as a set in
-- both directions, so a grant nobody wrote fails it as surely as a grant that
-- went missing. Adding a grant in a migration means adding its row here; that
-- is the point, not a chore.
--
-- PUBLIC's EXECUTE on functions is deliberately out of scope (Postgres's own
-- default, revoked case by case under gotcha 13), as are extension members.
begin;
set search_path to public, extensions;
select plan(7);

create temp table actual_grants on commit drop as
with ext as (
  select objid from pg_catalog.pg_depend where deptype = 'e'
)
select 'table'::text as kind, c.relname::text as obj, g.grantee::regrole::text as grantee,
       g.privilege_type::text as priv, null::text as col
from pg_catalog.pg_class c cross join lateral aclexplode(c.relacl) g
where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m')
  and c.oid not in (select objid from ext)
  and g.grantee in ('anon'::regrole, 'authenticated'::regrole)
union all
select 'column', c.relname, g.grantee::regrole::text, g.privilege_type, a.attname
from pg_catalog.pg_class c
join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
cross join lateral aclexplode(a.attacl) g
where c.relnamespace = 'public'::regnamespace and c.oid not in (select objid from ext)
  and g.grantee in ('anon'::regrole, 'authenticated'::regrole)
union all
select 'sequence', c.relname, g.grantee::regrole::text, g.privilege_type, null
from pg_catalog.pg_class c cross join lateral aclexplode(c.relacl) g
where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
  and c.oid not in (select objid from ext)
  and g.grantee in ('anon'::regrole, 'authenticated'::regrole)
union all
select 'function', p.oid::regprocedure::text, g.grantee::regrole::text, g.privilege_type, null
from pg_catalog.pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) g
where p.pronamespace = 'public'::regnamespace and p.oid not in (select objid from ext)
  and g.grantee in ('anon'::regrole, 'authenticated'::regrole);

create temp table allowed_grants (kind text, obj text, grantee text, priv text, col text) on commit drop;
insert into allowed_grants values
  ('column', 'direct_messages', 'authenticated', 'INSERT', 'author_id'),
  ('column', 'direct_messages', 'authenticated', 'INSERT', 'body'),
  ('column', 'direct_messages', 'authenticated', 'INSERT', 'id'),
  ('column', 'direct_messages', 'authenticated', 'INSERT', 'thread_id'),
  ('column', 'direct_reads', 'authenticated', 'INSERT', 'last_read_at'),
  ('column', 'direct_reads', 'authenticated', 'INSERT', 'thread_id'),
  ('column', 'direct_reads', 'authenticated', 'INSERT', 'user_id'),
  ('column', 'direct_reads', 'authenticated', 'UPDATE', 'last_read_at'),
  ('column', 'messages', 'authenticated', 'INSERT', 'author_id'),
  ('column', 'messages', 'authenticated', 'INSERT', 'body'),
  ('column', 'messages', 'authenticated', 'INSERT', 'id'),
  ('column', 'messages', 'authenticated', 'INSERT', 'party_id'),
  ('column', 'party_posts', 'authenticated', 'INSERT', 'author_id'),
  ('column', 'party_posts', 'authenticated', 'INSERT', 'body'),
  ('column', 'party_posts', 'authenticated', 'INSERT', 'id'),
  ('column', 'party_posts', 'authenticated', 'INSERT', 'media_type'),
  ('column', 'party_posts', 'authenticated', 'INSERT', 'party_id'),
  ('column', 'party_reads', 'authenticated', 'INSERT', 'last_read_at'),
  ('column', 'party_reads', 'authenticated', 'INSERT', 'party_id'),
  ('column', 'party_reads', 'authenticated', 'INSERT', 'user_id'),
  ('column', 'party_reads', 'authenticated', 'UPDATE', 'last_read_at'),
  ('column', 'post_comments', 'authenticated', 'INSERT', 'author_id'),
  ('column', 'post_comments', 'authenticated', 'INSERT', 'body'),
  ('column', 'post_comments', 'authenticated', 'INSERT', 'id'),
  ('column', 'post_comments', 'authenticated', 'INSERT', 'post_id'),
  ('column', 'post_likes', 'authenticated', 'INSERT', 'post_id'),
  ('column', 'post_likes', 'authenticated', 'INSERT', 'user_id'),
  ('column', 'reports', 'authenticated', 'INSERT', 'id'),
  ('column', 'reports', 'authenticated', 'INSERT', 'reason'),
  ('column', 'reports', 'authenticated', 'INSERT', 'reporter_id'),
  ('column', 'reports', 'authenticated', 'INSERT', 'target_id'),
  ('column', 'reports', 'authenticated', 'INSERT', 'target_type'),
  ('column', 'stories', 'authenticated', 'INSERT', 'author_id'),
  ('column', 'stories', 'authenticated', 'INSERT', 'content_type'),
  ('column', 'stories', 'authenticated', 'INSERT', 'id'),
  ('column', 'stories', 'authenticated', 'INSERT', 'party_id'),
  ('column', 'user_devices', 'authenticated', 'INSERT', 'id'),
  ('column', 'user_devices', 'authenticated', 'INSERT', 'last_location'),
  ('column', 'user_devices', 'authenticated', 'INSERT', 'platform'),
  ('column', 'user_devices', 'authenticated', 'INSERT', 'push_token'),
  ('column', 'user_devices', 'authenticated', 'INSERT', 'user_id'),
  ('column', 'user_devices', 'authenticated', 'UPDATE', 'last_location'),
  ('column', 'user_devices', 'authenticated', 'UPDATE', 'platform'),
  ('column', 'user_devices', 'authenticated', 'UPDATE', 'push_token'),
  ('function', 'cancel_account_deletion()', 'authenticated', 'EXECUTE', null),
  ('function', 'confirm_party_cover(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'confirm_post_upload(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'export_account_data()', 'authenticated', 'EXECUTE', null),
  ('function', 'get_direct_chats(timestamp with time zone,uuid,integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_direct_messages(uuid,timestamp with time zone,uuid,integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_feed(timestamp with time zone,uuid,integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_messages(uuid,timestamp with time zone,uuid,integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_my_hosted_parties(integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_my_parties()', 'authenticated', 'EXECUTE', null),
  ('function', 'get_or_create_direct_thread(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_parties_list(party_sort,integer,integer,bigint,timestamp with time zone,uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_parties_near_user(double precision,double precision,double precision,integer,text,text)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_party(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'get_party_chats()', 'authenticated', 'EXECUTE', null),
  ('function', 'get_profile_stats(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'has_location_consent(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'hide_direct_message(uuid,text)', 'authenticated', 'EXECUTE', null),
  ('function', 'is_party_host(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'map_search_box(double precision,double precision,double precision)', 'authenticated', 'EXECUTE', null),
  ('function', 'party_end_grace()', 'authenticated', 'EXECUTE', null),
  ('function', 'party_cover_upload_target(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'party_is_private(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'party_time_window(text,text,timestamp with time zone)', 'authenticated', 'EXECUTE', null),
  ('function', 'post_upload_target(uuid)', 'authenticated', 'EXECUTE', null),
  ('function', 'request_account_deletion()', 'authenticated', 'EXECUTE', null),
  ('function', 'rsvp_status_allowed(uuid,rsvp_status)', 'authenticated', 'EXECUTE', null),
  ('function', 'search_parties(text,integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'search_profiles(text,integer)', 'authenticated', 'EXECUTE', null),
  ('function', 'upsert_user_device(text,text,double precision,double precision)', 'authenticated', 'EXECUTE', null),
  ('table', 'blocks', 'authenticated', 'DELETE', null),
  ('table', 'blocks', 'authenticated', 'INSERT', null),
  ('table', 'blocks', 'authenticated', 'SELECT', null),
  ('table', 'direct_messages', 'authenticated', 'SELECT', null),
  ('table', 'direct_reads', 'authenticated', 'SELECT', null),
  ('table', 'direct_threads', 'authenticated', 'SELECT', null),
  ('table', 'follows', 'anon', 'SELECT', null),
  ('table', 'follows', 'authenticated', 'DELETE', null),
  ('table', 'follows', 'authenticated', 'INSERT', null),
  ('table', 'follows', 'authenticated', 'SELECT', null),
  ('table', 'invitations', 'authenticated', 'INSERT', null),
  ('table', 'invitations', 'authenticated', 'SELECT', null),
  ('table', 'messages', 'authenticated', 'SELECT', null),
  ('table', 'parties', 'anon', 'SELECT', null),
  ('table', 'parties', 'authenticated', 'DELETE', null),
  ('table', 'parties', 'authenticated', 'INSERT', null),
  ('table', 'parties', 'authenticated', 'SELECT', null),
  ('table', 'parties', 'authenticated', 'UPDATE', null),
  ('table', 'party_posts', 'anon', 'SELECT', null),
  ('table', 'party_posts', 'authenticated', 'SELECT', null),
  ('table', 'party_reads', 'authenticated', 'SELECT', null),
  ('table', 'party_search_tokens', 'authenticated', 'SELECT', null),
  ('table', 'post_comments', 'anon', 'SELECT', null),
  ('table', 'post_comments', 'authenticated', 'SELECT', null),
  ('table', 'post_likes', 'anon', 'SELECT', null),
  ('table', 'post_likes', 'authenticated', 'DELETE', null),
  ('table', 'post_likes', 'authenticated', 'SELECT', null),
  ('table', 'profiles', 'anon', 'SELECT', null),
  ('table', 'profiles', 'authenticated', 'SELECT', null),
  ('table', 'profiles', 'authenticated', 'UPDATE', null),
  ('table', 'reports', 'authenticated', 'SELECT', null),
  ('table', 'rsvps', 'authenticated', 'DELETE', null),
  ('table', 'rsvps', 'authenticated', 'INSERT', null),
  ('table', 'rsvps', 'authenticated', 'SELECT', null),
  ('table', 'rsvps', 'authenticated', 'UPDATE', null),
  ('table', 'stories', 'authenticated', 'SELECT', null),
  ('table', 'story_views', 'authenticated', 'INSERT', null),
  ('table', 'story_views', 'authenticated', 'SELECT', null),
  ('table', 'user_birthdates', 'authenticated', 'SELECT', null),
  ('table', 'user_devices', 'authenticated', 'DELETE', null),
  ('table', 'user_devices', 'authenticated', 'SELECT', null);

-- ---------------------------------------------------------------- the set
select is_empty(
  $$ select * from actual_grants except select * from allowed_grants $$,
  'no client grant exists that the allow-list does not name (the image defaults are gone)'
);

select is_empty(
  $$ select * from allowed_grants except select * from actual_grants $$,
  'and every grant the allow-list names is present -- nothing was over-revoked'
);

-- ---------------------------------------------------------------- the defaults
select is_empty(
  $$ select d.defaclobjtype, g.grantee::regrole, g.privilege_type
     from pg_catalog.pg_default_acl d cross join lateral aclexplode(d.defaclacl) g
     where d.defaclnamespace = 'public'::regnamespace
       and d.defaclrole = 'postgres'::regrole
       and g.grantee in ('anon'::regrole, 'authenticated'::regrole) $$,
  'the postgres default privileges in public grant anon/authenticated nothing'
);

create table public.zz_grant_probe (id int);
create function public.zz_grant_probe_fn() returns int language sql as $$ select 1 $$;

select ok(
  not has_table_privilege('anon', 'public.zz_grant_probe', 'SELECT')
  and not has_table_privilege('authenticated', 'public.zz_grant_probe', 'SELECT,INSERT,UPDATE,DELETE'),
  'a table created now starts with no client privileges at all'
);

select is_empty(
  $$ select 1 from pg_catalog.pg_proc p cross join lateral aclexplode(p.proacl) g
     where p.oid = 'public.zz_grant_probe_fn()'::regprocedure
       and g.grantee in ('anon'::regrole, 'authenticated'::regrole) $$,
  'and a function created now carries no explicit anon/authenticated grant'
);

-- ---------------------------------------------------------------- spot checks
-- Redundant with the set comparison on purpose: these are the two that read
-- as an incident if they regress, and a set diff is a poor error message.
select ok(
  not has_table_privilege('anon', 'public.messages', 'SELECT'),
  'anon cannot read messages at the grant level'
);

select ok(
  not has_column_privilege('authenticated', 'public.user_devices', 'last_location_at', 'UPDATE'),
  'the retention clock stays unwritable (gotcha 8)'
);

select * from finish();
rollback;
