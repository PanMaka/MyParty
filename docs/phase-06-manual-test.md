# Phase 6 — manual two-device test plan

What pgTAP cannot check: that the socket actually carries the message, that a
dropped connection recovers, and that the non-invitee's client is refused the
channel rather than quietly filtered. Run this on two devices (or two
browser profiles — `flutter run -d chrome` twice works and makes the DevTools
step below far easier).

`supabase test db` already proves the *authorization*; this plan proves the
*delivery*.

## Setup

```
supabase start
supabase db reset          # seeds the personas below
cd myparty && flutter run
```

Seeded accounts, password `password123` for all:

| Device | Account                     | Relationship to `Rooftop Pregame` |
|--------|-----------------------------|-----------------------------------|
| **A**  | `host@myparty.local`        | host                              |
| **B**  | `invitee@myparty.local`     | invited                           |
| **C**  | `stranger@myparty.local`    | **not invited** — the control     |

`Rooftop Pregame` is `aaaaaaaa-0000-0000-0000-000000000001`, private.
`Syntagma Afterparty` is `aaaaaaaa-0000-0000-0000-000000000002`, public.

## 1. Live delivery

1. A and B both open **Μηνύματα → Rooftop Pregame**.
2. A sends `door code is 4471`.
3. **Expect**: it appears on B within a second, without B touching anything.
   On A it appears instantly (optimistic), then settles — and stays **one**
   bubble, not two, when the broadcast echo arrives.
4. B replies. Same in reverse.

## 2. The verification bar — a non-invitee receives nothing

This is the assertion the phase exists for, and it has two halves.

**Half one, the list.** On C, open **Μηνύματα**. `Rooftop Pregame` must not be
listed at all. `Syntagma Afterparty` must also be absent — C has not RSVP'd,
and chat requires participation, not merely visibility.

**Half two, the socket.** C cannot navigate to the chat through the UI, which
is the point — so prove the server would refuse anyway:

1. Run C as `flutter run -d chrome`, open DevTools → **Network → WS**.
2. In the JS console on C, force a subscribe to the topic C must not have:

   ```js
   // Paste into the C tab's console. The client is the app's own.
   const ch = supabase.channel('party:aaaaaaaa-0000-0000-0000-000000000001',
                               { config: { private: true } });
   ch.subscribe((status, err) => console.log('STATUS', status, err));
   ```

   If the app does not expose `supabase` globally, use `curl` instead — the
   REST equivalent hits the same policy:

   ```bash
   # Sign in as stranger, then:
   curl -s "$API_URL/rest/v1/rpc/get_messages" \
     -H "apikey: $ANON_KEY" -H "Authorization: Bearer $STRANGER_JWT" \
     -H 'Content-Type: application/json' \
     -d '{"p_party_id":"aaaaaaaa-0000-0000-0000-000000000001"}'
   # Expect: []
   ```

3. **Expect** `STATUS CHANNEL_ERROR` and, in the WS frames, a `phx_reply` with
   `"status":"error"` — the join is **refused**. Not an empty channel: a
   refused one.
4. Now have A send another message in the party. **Expect nothing at all in
   C's WS frames** — no `broadcast` frame, no payload, no filtered event. The
   message is not delivered-then-hidden; C is not on the topic.

Repeat step 3 with B's token to see the contrast: `STATUS SUBSCRIBED`, and A's
next message shows up as a `broadcast` frame carrying the body.

## 3. The tightened membership rule

The public party is where `can_chat_in_party` differs from
`can_access_party`, so it needs its own pass.

1. On C, open the map and tap `Syntagma Afterparty`. C **can see** the party.
2. Open **Μηνύματα** — the chat is still not listed. Seeing a party is not
   joining its conversation.
3. Give C an RSVP (from **Εκδηλώσεις**, or directly):
   ```sql
   insert into public.rsvps (party_id, user_id, status) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '44444444-4444-4444-4444-444444444444', 'interested');
   ```
4. Pull to refresh **Μηνύματα** on C. **Expect** the chat now appears, with
   history, and C can post.

## 4. Reconnect and the gap-fill

The one behaviour that only shows up on a real socket.

1. A and B both in `Rooftop Pregame`.
2. Put **B** in airplane mode (or kill the network / stop the Docker
   `supabase_realtime` container for ~20s).
3. While B is offline, A sends three messages.
4. Bring B back online.
5. **Expect** all three appear on B within a second or two of reconnect,
   in order, with no duplicates and no gap. They arrive from
   `fetchMessagesSince`, not from the socket — broadcast has no replay, so if
   this step shows only the messages sent *after* reconnect, the gap-fill is
   broken.
6. Scroll up in B. **Expect** older history pages in smoothly with no repeated
   or skipped messages at the page boundary.

## 5. Unread counts

1. B leaves the chat (back to **Μηνύματα**).
2. A sends two messages.
3. **Expect** a `2` badge on B's `Rooftop Pregame` row, and the preview line
   updates to A's latest.
4. B opens the chat, then goes back. **Expect** the badge is gone.
5. Kill and reopen B's app. **Expect** the badge is still gone — the watermark
   is server-side, not local state.

## 6. Moderation reaches open clients

1. A, B both in the chat. B sends `something regrettable`.
2. B long-presses **A's** message → nothing should let B hide it (`hide_message`
   returns 42501; the sheet shows «Δεν έγινε»).
3. A long-presses B's message → **Απόκρυψη μηνύματος**.
4. **Expect** the message disappears from **B's screen too, without B
   reloading** — that is the `message_hidden` broadcast doing its job. If it
   only disappears after reopening the screen, the retraction event is not
   firing.

## 7. Rate limit

1. On A, paste-and-send 21 messages as fast as possible into one party.
2. **Expect** the first 20 land; the 21st comes back marked
   «Δεν στάλθηκε. Δοκίμασε ξανά.» rather than silently vanishing.
3. Switch to a different party A participates in and send. **Expect** it goes
   through — the limit is per (user, party), so one flooded chat does not gag
   the others.

## What a failure means

| Symptom | Where to look |
|---|---|
| B never receives anything, no error | `private: true` missing on the channel, or the client has no auth token on the socket |
| C's subscribe **succeeds** | the `realtime.messages` SELECT policy — this is a leak, stop and fix before merging |
| C receives a frame it then hides | you are on `postgres_changes` somewhere, not broadcast |
| Own message appears twice | the client-generated id is not surviving the insert; check the `id` column grant |
| Messages lost across a reconnect | `fetchMessagesSince` / the `_hasSubscribedOnce` gate in `ChatScreen` |
| Badge returns after reopening the app | `markRead` not reaching `party_reads`, or the clamp trigger rejecting the write |
