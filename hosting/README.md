# mypartycorp.com — what the domain must serve for party links

Party links are `https://mypartycorp.com/p/<party uuid>` (`myparty/lib/utils/party_link.dart`).
The Android app claims them with a verified App Link (`autoVerify` in
`AndroidManifest.xml`). For that to work the domain must serve two things.

## 1. `/.well-known/assetlinks.json` — required

Copy `mypartycorp.com/.well-known/assetlinks.json` to the site so it is reachable at
exactly `https://mypartycorp.com/.well-known/assetlinks.json`, and check:

- **HTTPS, status 200, no redirect.** Android does not follow redirects for this
  file — not http→https, not apex→www.
- **`Content-Type: application/json`.**
- **Reachable without login, cookies or a bot challenge** (Cloudflare "under attack"
  mode and similar break verification).

Test it with Google's checker:
`https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://mypartycorp.com&relation=delegate_permission/common.handle_all_urls`

### What is in it, and what has to change before release

- `package_name` is `com.example.myparty` — Flutter's placeholder. Google Play
  rejects `com.example.*`, so the app id must change before publishing
  (`applicationId` in `android/app/build.gradle.kts`, and the Firebase config if push
  is on), and this file with it.
- `sha256_cert_fingerprints` holds **one developer's debug key**. Every machine has its
  own debug key, so a teammate's debug build will not verify unless their
  fingerprint is added too:
  `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
  For release, add the **Play App Signing** key's SHA-256 (Play Console → Setup → App
  signing), not just the upload key's. The array may hold several fingerprints.

## 2. `/p/<anything>` → `mypartycorp.com/p/index.html` — strongly recommended

The page people **without** the app see. Configure the host to serve
`p/index.html` for every path under `/p/` (a rewrite, not a redirect — the address
bar should keep the link). For example:

- Netlify `_redirects`: `/p/*  /p/index.html  200`
- Vercel `vercel.json`: `{ "rewrites": [{ "source": "/p/:id", "destination": "/p/index.html" }] }`
- nginx: `location /p/ { try_files /p/index.html =404; }`

The page is static, identical for every id, and says nothing about the party — see
the comment at the top of it for why. Keep it that way: rendering a party's details
here would need a server reading the database outside the viewer's session, which
is exactly what the parties policy exists to prevent.

## 3. `/i` → `mypartycorp.com/i/index.html` — required for invite links (Phase 40)

Invite links are `https://mypartycorp.com/i#<token>` (`inviteLink` in
`party_link.dart`). The token is in the **fragment**, which browsers never send to
the server, so every invite link requests exactly `/i`. Without a rewrite,
someone without the app gets a 404. Serve `i/index.html` for `/i` (a rewrite, not
a redirect):

- Cloudflare Pages: the `_redirects` file next to this README's site folder
  (`mypartycorp.com/_redirects`) already holds the rule, `/i  /i/index.html  200`,
  together with the `/p/*` one.
- Netlify `_redirects`: the same file works unchanged.
- Vercel: `{ "rewrites": [{ "source": "/i", "destination": "/i/index.html" }] }`
- nginx: `location = /i { try_files /i/index.html =404; }`

Like the `/p/` page it is static and says nothing about the party. It must also
**never run a script**: a script could read the fragment, and the fragment is the
key. Its Content-Security-Policy forbids scripts, so keep it that way.

The Android intent filter claims `/i` too (`android:path="/i"` in
`AndroidManifest.xml`). Verification is per host, so the existing
`assetlinks.json` already covers it; nothing in that file changes.

## Testing before the domain serves the file

Without a verified `assetlinks.json`, Android 12+ opens these links in the browser.
To test the app's handling anyway, either send the intent straight to the app:

```
adb shell am start -W -a android.intent.action.VIEW \
  -d "https://mypartycorp.com/p/<party uuid>" com.example.myparty

# An invite link. Quote it: the # would start a comment in the shell.
adb shell am start -W -a android.intent.action.VIEW \
  -d "'https://mypartycorp.com/i#<43-character token>'" com.example.myparty
```

or approve the domain for the app by hand (what the user would do under Settings →
Apps → myparty → Open by default):

```
adb shell pm set-app-links-user-selection --user cur --package com.example.myparty true mypartycorp.com
```
