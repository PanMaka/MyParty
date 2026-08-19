# Phase 10 — Hardening audit

Everything below was measured against the local stack at
`20260819095452`, not read off a dashboard. Reproduce with:

```
supabase db reset
supabase test db                          # 13 files, 430 assertions
bash scripts/loadtest_map_query.sh        # 10k parties / 50k rsvps
```

---

## 0. The headline

**`get_parties_near_user` takes ~1 second at 10k parties, and 99.7% of that is
RLS.** The GiST index on `parties.location` is never used when the query runs
as a signed-in user — the row policy forces a sequential scan over every party
in the table. Same query, same rows, policies off: **2ms**.

That is the answer to "what breaks first", it is not fixed in this phase, and
§5 has the numbers and the proposed fix.

---

## 1. `get_advisors`, and why its output needed translating

The linked hosted project `faffajfecsincrfindrz` is at **4 migrations**. Local
is at **45**, only three of which the hosted project has ever seen. The
advisor therefore linted a schema from Phase 1, and two of
its four performance findings were already fixed in Phase 8. Its output is
reproduced here with a verdict against *today's* schema.

### Security

| Finding | Level | Verdict |
|---|---|---|
| `function_search_path_mutable` — `get_parties_near_user` | WARN | **Fixed** (`20260819095452`), and it was true of seven more functions the hosted schema does not have yet. All eight now pin `search_path`. |
| `function_search_path_mutable` — `protect_credibility_score` | WARN | **Already fixed** — it carries `search_path=""` today. |
| `rls_disabled_in_public` — `public.spatial_ref_sys` | ERROR | **Deliberately left.** See below. |
| `extension_in_public` — `postgis` | WARN | **Deliberately left.** Root cause of the one above. |
| `anon_security_definer_function_executable` — `st_estimatedextent` ×3 | WARN | **Deliberately left.** PostGIS's own functions; same ownership problem. |
| `anon_security_definer_function_executable` — `rls_auto_enable` | WARN | **Not applicable.** That function exists only in the hosted project's Phase 0 baseline; it is in no migration in this repo and not in the local schema. |
| `auth_leaked_password_protection` disabled | WARN | **Open, and yours to click.** It is an Auth dashboard toggle, not schema — no migration can set it. Worth enabling before launch. |

### Performance

| Finding | Verdict |
|---|---|
| `unindexed_foreign_keys` — `invitations_guest_id_fkey` | **Fixed** (`20260819093230`). |
| `unindexed_foreign_keys` — `parties_host_id_fkey` | **Already fixed** in Phase 8. |
| `auth_rls_initplan` on `parties` | **Already fixed** — every policy in the schema uses `(select auth.uid())`. |
| `unused_index` — `parties_location` | **Wrong, and interestingly so.** It is unused on the hosted project because nothing queries it there. It is also unused *locally under RLS* — see §5. Do not drop it; the fix is to make the query able to use it. |

### Why the linter cannot be the control

It runs against a project this schema does not live in, and even pointed at the
right database it is a page someone has to remember to open. So every rule
above that is expressible over the catalog is now a pgTAP assertion in
`supabase/tests/database/13_hardening.test.sql` (group A): RLS on every table,
no non-data grants to `anon`/`authenticated`, `search_path` on every function,
`search_path=""` specifically on every SECURITY DEFINER function, a covering
index on every foreign key. They run on every `supabase test db`.

### `spatial_ref_sys`, the one ERROR left standing

It is the only table in `public` with RLS off, and unlike ours it carries real
data privileges: `anon` holds INSERT, UPDATE and DELETE on it, straight from
PostGIS's grants, over PostgREST.

It cannot be fixed from a migration. The table is owned by `supabase_admin`,
its grants were issued by `supabase_admin`, and `postgres` — the role
migrations run as — is neither a member of that role nor a superuser
(`pg_auth_members` has no such edge). Both `alter table … enable row level
security` and `revoke … from anon` fail with 42501. Putting either in a
migration would break every `supabase db reset`.

The root cause is PostGIS being installed in `public` instead of `extensions`.
Moving it is not a hardening change: `alter extension postgis set schema
extensions` rewrites the resolution of every geography column, index operator
class and `st_*` call in the schema, and this schema has two geography columns,
two GiST indexes and a proximity engine whose query plans are asserted by
script. It needs its own migration and its own re-measurement.

What is actually at risk: `spatial_ref_sys` is a lookup table of coordinate
system definitions. Every geometry in this project is SRID 4326, whose row is
re-inserted by any PostGIS upgrade. The exposure is bloat and vandalism, not
disclosure. It is allowlisted **by name** in the test so removing the exception
has to be deliberate.

---

## 2. The default ACL sweep

Supabase's default privileges grant `anon`, `authenticated` and `service_role`
`TRUNCATE`, `REFERENCES`, `TRIGGER` and `MAINTAIN` on every table created in
`public`. Phase 7a revoked them on three tables; **fifteen still carried them**,
and `pg_default_acl` would have kept adding them to new ones.

Not an incident: none of the four reads or writes a row, so no policy is
bypassed, and PostgREST exposes no route to any of them. Worth a migration
anyway, because **RLS does not mediate TRUNCATE** — an RLS-perfect table is
still one statement away from empty for anyone holding the privilege, and
`REFERENCES` lets a role pin your rows against deletion with a foreign key.

`20260819092958` revokes them from all nineteen tables, from the three
sequences (`UPDATE` on a sequence is what `setval()` checks), and from the
default privileges so table twenty does not inherit them. `service_role` keeps
its grants: it holds the service key and bypasses RLS by design, so TRUNCATE is
not a boundary there.

---

## 3. The index audit — what was missing, and what was not

The stated rule is "every FK used in a join needs an index". Applied literally
to 36 foreign keys it produces a shrug, because most are already covered by a
primary key or unique constraint that leads with the right column. The useful
question is narrower: **which foreign key has a real query behind it that no
index can answer.**

Two workloads answer it, and neither is a screen. Both arrived in Phase 9.

- **`complete_account_erasure`** is the only code path that filters *every*
  child table by one user id. It runs from a cron under the service key, so
  when it seq-scans nobody is waiting and nothing in the app gets slower — it
  just costs more every month, silently. Eight of its ten deletes were indexed;
  two were not.
- **`export_account_data`** does the same shape in reverse: `where author_id = ?
  order by created_at` against three tables. `messages` is the largest table in
  the schema, and a GDPR subject-access request was reading all of it.

Plus one cascade a user triggers by hand — the only entry here that is latency
rather than cost.

### Added

| Index | Driven by |
|---|---|
| `invitations (guest_id)` | `complete_account_erasure` |
| `party_reads (user_id)` | `complete_account_erasure` |
| `notification_jobs (party_id)` | `parties` DELETE cascade — hosts can delete their own parties |
| `sent_notifications (party_id)` | same cascade |
| `party_posts (author_id, created_at)` | `export_account_data` |
| `post_comments (author_id, created_at)` | `export_account_data` |
| `messages (author_id, created_at)` | `export_account_data` |

Ascending on `created_at`, unlike every other timestamp index here, because the
export reads a life oldest-first while the feeds paginate newest-first. A btree
walks backwards at the same cost, so the direction records which query the
index is *for*. No `where hidden_at is null` predicate either: the export must
hand the subject the rows a moderator hid, with `hidden_at` and `hidden_reason`
attached.

### Deliberately not added

- **Five `hidden_by` foreign keys.** `on delete set null` to `profiles`. The
  column is null on nearly every row, and since Phase 9 the parent is a
  tombstone that is never deleted — so the cascade the index would serve cannot
  fire. Pure write amplification on five insert paths.
- **`story_media_purges.story_id`.** `stories` are hidden, never deleted.
- Everything else: already covered.

Both lists are enforced by the test — the exception list lives there too, so
adding to it is a code change someone reviews.

### Policies with subqueries

Every RLS policy in `public` that contains a subquery was checked. All of them
reach `parties` by primary key, `party_posts` by primary key, or a helper whose
own lookups (`invitations(party_id, guest_id)`, `rsvps(party_id, user_id)`,
`follows(follower_id, followee_id)`, `blocks(blocker_id, blocked_id)`) ride a
unique index. No policy needed a new index. The problem with the policies is
not indexing — see §5.

---

## 4. Rate limits

Messages (20 per 10s per user+party) and stories (10/hour per user) already
had one. Added in `20260819093446`:

| Path | Limit | Scope, and why |
|---|---|---|
| `party_posts` | 30/hour | Per user globally. A post carries media and lands in `get_feed`, so the resource is storage and other people's feeds — both global to the account. |
| `post_comments` | 100/hour | Per user globally. Comment spam is *breadth* — one line under fifty strangers' posts — so a per-post cap would price the harmless case and leave the harmful one free. |
| `invitations` | 500/party, 1000/hour/host | Two caps answering two questions: a guest-list size limit, and the rate limit proper. Without the second, the first costs an attacker one extra `create_party_with_invites` call per 500 invites. |

### The thing that turned out not to be true

The plan for this phase assumed a `before insert` row trigger cannot see the
rows inserted earlier in its own statement, and that a bulk insert would
therefore slip past every existing limit. **It is false, and it was measured
rather than reasoned:** a single `insert into stories select … from
generate_series(1,15)` is refused at row 11 by the Phase 5 trigger, and 25
messages in one statement are refused at 21. A query inside a volatile plpgsql
function takes a fresh snapshot whose `curcid` is the current command id, so
rows with `cmin` equal to that cid are visible to it.

That property is what makes every per-row limit in this schema sound against a
PostgREST array insert (`POST /rest/v1/party_posts` with 50 objects is one
statement), so it is now asserted in the test suite for both posts and stories.

The invitations trigger is still statement-level — but for **cost**, not
correctness. `create_party_with_invites` writes the whole guest list as one
`insert … select from unnest()`, so a row trigger would run 500 counting
queries to answer a question that has one answer.

---

## 5. Load test — and what breaks first

10,022 parties · 50,112 rsvps · 5,006 profiles · 200 follows · 108 invitations.
Measured as an authenticated viewer with RLS in force, 100 samples per cell,
two interleaved rounds so drift lands on every variant equally.

### Latency

| Zoom | Variant | rows | p50 | p95 |
|---|---|---|---|---|
| 5km | as shipped | 222 | **995 ms** | 1102 ms |
| 5km | `search_path` pinned | 222 | 992 ms | 1112 ms |
| 5km | STABLE + inlined | 222 | 983 ms | 1109 ms |
| 5km | **RLS bypassed (control)** | 267 | **2.05 ms** | 2.77 ms |
| 50km | as shipped | 1326 | 230 ms | 270 ms |
| 50km | RLS bypassed (control) | 1546 | 8.91 ms | 11.9 ms |
| 500km | as shipped | 1055 | 208 ms | 233 ms |
| 500km | RLS bypassed (control) | 1230 | 7.77 ms | 8.88 ms |

RLS is **99.7% / 95.6% / 96.2%** of p95 at the three zoom levels.

### What breaks first: the row policy defeats the GiST index

The plan under RLS, at 5km:

```
Seq Scan on parties p  (actual time=0.284..1021.255 rows=275)
  Filter: (((ends_at IS NULL) OR (ends_at > now()))
           AND can_access_party(id)
           AND (status = 'published')
           AND st_dwithin(location, <point>, 5000))
  Rows Removed by Filter: 9747
  Buffers: shared hit=53191
```

The same query with the policies off:

```
Bitmap Heap Scan on parties p  (actual time=0.104..0.614 rows=333)
  ->  Bitmap Index Scan on parties_location  (rows=565)
        Index Cond: (location && _st_expand(<point>, 5000))
  Buffers: shared hit=220
```

Two things are happening, and the second is the interesting one.

1. **`can_access_party(id)` is called once per row — 10,022 times.** It is a
   SECURITY DEFINER function that runs a subquery on `parties`, calls
   `is_blocked` (another definer function, another query), and may probe
   `invitations`. Three nested queries per row, ~0.1ms each.

2. **It runs *before* `st_dwithin`, which is why the index is gone.** An RLS
   qual is a security barrier: Postgres will not evaluate a non-leakproof user
   qual ahead of it, because doing so could leak the contents of rows the user
   cannot see. `st_dwithin` is not leakproof, so it cannot be pushed down into
   an index condition, and the most selective predicate in the query — the one
   the GiST index exists for — is evaluated last, on rows that have already
   paid for the expensive function.

This gets **worse as you zoom in**, which is backwards from intuition and from
where the users are. At 500km the tier filter (`party_tier = 'mega' or
is_sponsored`) is cheap, non-leaky and highly selective, so it runs first and
`can_access_party` is asked about far fewer rows — 208ms. At 5km the tier
branch of the `case` is a literal `true`, there is no cheap pre-filter, and the
full 10k rows go through the policy — 995ms. The most common interaction in
the app is the slowest.

### The fix, proposed and not applied

Rewrite the `parties` SELECT policy so the cheap columns it already has access
to answer most rows without a function call:

```sql
-- today
using (can_access_party(id))

-- proposed
using (
  not is_blocked((select auth.uid()), host_id)
  and (not is_private or can_access_party(id))
)
```

`can_user_access_party` re-fetches the `parties` row it was handed the id of,
purely to read `is_private` and `host_id` — two columns the policy already has
in hand. Hoisting them removes a nested query per row and short-circuits every
public party, which is most of them. It is not a change in who can see what:
the terms are the same terms in the same order the helper applies them.

It is **not in this phase** because it rewrites the single policy with the
widest blast radius in the schema — the one `20260812121153` already had to fix
a recursion in — and that deserves its own branch, its own pgTAP matrix and its
own re-measurement rather than a footnote in a hardening PR.

### The `search_path` question, answered

Pinning cost **+9.8ms / −13.7ms / +9.1ms** at p95 across the three tiers. The
deltas do not agree on a sign; it is free, and the migration shipped.

The premise it was supposed to test turned out to be wrong in an instructive
way. A `language sql` set-returning function is inlined only if it is not
SECURITY DEFINER, **not VOLATILE**, and has no SET clause. All eight read RPCs
are VOLATILE — nobody declared otherwise and VOLATILE is the default — so none
of them has ever been inlined. `explain select * from
get_parties_near_user(…)` prints one line, `Function Scan`; the identical body
declared STABLE prints a 37-line plan. Pinning `search_path` did not cost
inlining, because there was none to lose; it costs the *option* of gaining it,
which the STABLE variant prices at nothing (983ms vs 995ms) as long as the
policy dominates. If §5's policy fix ever lands, that option is worth
re-pricing.

---

## Left open

| Item | Why |
|---|---|
| The `parties` policy rewrite | §5. Own branch, own tests. |
| PostGIS out of `public` / `spatial_ref_sys` | §1. Needs superuser or a Supabase support action, plus re-measurement of every spatial plan. |
| Leaked-password protection | §1. Dashboard toggle, not schema. |
| `supabase db push` to hosted | 42 of this repo's 45 migrations have never been applied there. Bringing it current is a deployment decision, not hardening. |
