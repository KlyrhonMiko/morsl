# morsl

**Little bites. Our little history.**

A native Flutter beta for keeping meals as personal scrapbook memories. The app
runs locally before sign-in. Capture → durable draft → optional cutout → Plating
→ save → invite → History / Map. Cutout quality never gates the rest of the app.

## Run the local beta

```powershell
flutter pub get
flutter run -d <your-android-device-id>
```

Open Settings → Beta notebook → **Download dish models · 249 MB** once before
using automatic cutouts offline. Android downloads pinned, SHA-256 verified
Grounding DINO Tiny and MobileSAM models. Detection finds dishes across the photo;
each detected dish gets its own transparent mask and independent placement.
New imports run this automatically. For older merged results, **Separate dishes**
in Plating replaces the current cutouts in one step. It can reset existing plate
positions and edge edits, so use it when you want to regenerate them.

This workflow targets Android only. All inference runs on the phone; model
preparation only downloads public weights and never sends a photo. Processing
can take tens of seconds depending on the phone. Recognition is not guaranteed
for every photo, and parts outside the photo or behind another dish cannot be
reconstructed. Optional **Select a plate** and **Edit edges** tools remain for
corrections. See [model notices](THIRD_PARTY_MODELS.md) for provenance/licenses.

First launch includes clearly labeled example memories and an example draft.
Saved examples include bundled transparent food cutouts from their source photos;
existing examples are upgraded in place. Newly captured meals automatically show
their first successful cutout, and an explicit original-photo choice is preserved.
They stay local, never upload, and can be cleared in Settings. Camera and import
create real meals. Windows has an import/editor fallback; its runner requires
Visual Studio's C++ workload. This project is a native mobile app, not a web app.

The test APK is `build/app/outputs/flutter-apk/app-debug.apk`.
Rendered UI previews are in `output/previews/`.

## Connect backup, invitations, and maps

1. Create a Supabase project. Apply
   `supabase/migrations/202610050001_beta.sql` using the Supabase CLI or SQL editor.
   This creates the private `meal-images` bucket, RLS policies, and RPCs.
2. Configure email/password Auth and email confirmation for your beta. Create two
   test accounts through the app. Invitations require an existing account.
3. Deploy `supabase/functions/nearby-venues`. Keep the Places key on the server:
   `supabase secrets set GOOGLE_PLACES_API_KEY=<server-key>` then
   `supabase functions deploy nearby-venues`. The function validates the caller
   with Supabase Auth. Configure quotas and key restrictions in Google Cloud.
4. Enable Maps SDK for Android and Places API (New). Restrict mobile
   Maps keys to your final bundle/package IDs and signing certificates. This
   starter uses `com.example.morsl`; choose your production IDs before publishing.
5. Copy `config.example.json` to gitignored `config.local.json` and fill in the
   Supabase URL, **publishable/anon client key**, and mobile Maps key. Never put a
   Supabase service-role key or a server Places key in the app.
6. Run `flutter run --dart-define-from-file=config.local.json`. Android reads the
   Maps key from the same defines and supplies it to its manifest.


No keys are checked in. Without service configuration, capture, durable drafts,
cutout fallback, editing, local History, evaluation, and notification settings
remain available. The Map shows a labeled illustration and local locations;
cloud actions explain their configuration state instead of pretending success.

## What is implemented

- Riverpod app dependency/state ownership; Drift/SQLite transactions and separate
  meal, asset, personal-memory, job, sync, evaluation, preference, and event data.
- Original photos in application documents, never large SQLite image blobs.
  Thumbnails are generated away from the UI thread. Imports use available EXIF
  capture dates/GPS and offer correction. Lost Android picker results are recovered.
- Separate plate masks, normalized source regions, independent placement, and
  content-addressed local PNGs. Backups preserve masks and rebuild the plate
  images from the original; existing single-cutout memories remain compatible.
- Native cutout adapter: availability, explicit preparation, processing, typed
  failure handling. Successful cache outputs are copied to durable storage.
  Interrupted jobs return to the queue at launch; originals remain editable.
- Plating: three presets, four paper backgrounds, normalized drag/scale/rotation,
  keyboard-accessible sliders, photo/cutout choice, reset, metadata, autosave, save.
- Chronological scrapbook, caption/venue/companion search, companion/date/repeat
  filters, bookmark, open/edit/archive; evening reminders scoped to the account,
  scheduled for unfinished drafts independently of AI completion.
- Confirmed map locations, Google Maps clustering, memory pin opening, companion
  and repeat filters, offline list. Venue suggestions are live and user-confirmed.
  Only place IDs persist; user-entered labels and captured coordinates stay separate.
- Guest use and explicit account association. Account-scoped UI, records, files,
  and reminder preferences; content-addressed storage, persistent/coalesced sync
  operations, backoff/manual retry, revision conflicts and explicit resolution.
- Private meal invitations, acceptance/decline, independent recipient annotations,
  leaving, uploader photo removal, personal archive, and confirmed creator deletion.
  Revocation is checked before asset restoration and purges app-managed local caches.
  Deleted meals retain a server tombstone to prevent stale-device resurrection.
- Cutout comparisons, quality/failure labels, timings, hardware/OS/runtime details,
  model preparation, processing and backup queue status, JSON evaluation export.
  Local events include editing duration, revisits, sync failures, and restoration.

## Verification

```powershell
flutter analyze
flutter test
flutter build apk --debug
```

`test/data_test.dart` verifies persistence/reopen, exact transforms, job recovery,
original fallback, concurrent editing during extraction, account isolation,
backup interruption/idempotency, and acknowledgements of older queue operations.
`test/widget_test.dart` exercises search/navigation, saving after AI failure, and
renders 375×812, 812×375, and 1440×1000 previews with real photos and fonts.

The backend test uses PGlite (PostgreSQL in WASM) with mocked Supabase Auth/Storage
schemas and three synthetic identities. It tests actual SQL/RLS, not Dart mocks:

```powershell
npm install --prefix "$env:TEMP/morsl-postgres-verification" --no-audit --no-fund @electric-sql/pglite
node test/backend_security.mjs
```

This validates the migration and authorization/revision logic locally; it does
not replace real Supabase Auth, Storage HTTP access, or two-account device tests.
Physical-device cutout quality and live two-account service verification remain release gates.

## Scope and operational notes

No public feed, restaurant ranking, automatic dish naming, or individual-plate
extraction. Processing is active-app work with launch recovery, not a promise of
execution after termination. Background workers can be added after device testing.
Guest originals remain local until explicitly associated with an account. JSON
beta exports contain IDs and device details; export is a deliberate user action.

Storage paths are immutable content addresses. An interrupted upload may leave
an unreferenced object; these are inaccessible to other participants. Before a
larger rollout, schedule server cleanup for unreferenced versions and assets of
deleted meals. Configure server-side venue quotas/rate limits and the project's
privacy policy/terms URL. The APK uses debug signing and is for beta testing;
store distribution needs your signing configuration.

Technical references: [offline model provenance](THIRD_PARTY_MODELS.md),
[Places policies](https://developers.google.com/maps/documentation/places/web-service/policies),
[Supabase database RLS](https://supabase.com/docs/guides/database/postgres/row-level-security),
[Storage access](https://supabase.com/docs/guides/storage/security/access-control).
Fonts are bundled with OFL licenses. Photo sources are in `docs/assets.md`.
