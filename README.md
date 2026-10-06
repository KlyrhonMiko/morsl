# morsl

**Little bites. Our little history.**

A native Flutter beta for keeping meals as personal scrapbook memories. The app
runs in browse-only mode before Google sign-in. Sign in → capture → durable draft → optional cutout → Plating
→ save → invite → History / Map. Cutout quality never gates the rest of the app.

## Run the local beta

```powershell
flutter pub get
flutter run -d <your-android-device-id>
```

Automatic cutouts use the cloud segmentation endpoint on Modal and require an
internet connection, Google sign-in, and explicit cloud-processing consent.
No local model download is required. Approved photos are uploaded for processing.
Each detected dish gets its own
transparent mask and independent placement.
New imports run this automatically when cloud cutouts are enabled in Settings.
For older merged results, **Separate dishes**
in Plating replaces the current cutouts in one step. It can reset existing plate
positions and edge edits, so use it when you want to regenerate them.

Recognition is not guaranteed for every photo, and parts outside the photo or
behind another dish cannot be
reconstructed. Optional **Select a plate** and **Edit edges** tools remain for
corrections and work offline. See [cloud architecture](modal_architecture.md)
for the current deployment script and client integration.

First launch includes clearly labeled example memories and an example draft.
Saved examples include bundled transparent food cutouts from their source photos;
existing examples are upgraded in place. Newly captured meals automatically show
their first successful cutout, and an explicit original-photo choice is preserved.
Bundled examples stay local and never upload. Google sign-in is required for camera,
import, manual editing, bookmarks, sharing, exports, and changes to settings. Guests
can browse and search the example scrapbook. Camera and import
create real meals. Windows has an import/editor fallback; its runner requires
Visual Studio's C++ workload. This project is a native mobile app, not a web app.

The test APK is `build/app/outputs/flutter-apk/app-debug.apk`.
Rendered UI previews are in `output/previews/`.

## Connect backup, invitations, and maps

1. Create a Supabase project. Apply
   `supabase/migrations/202610050001_beta.sql` using the Supabase CLI or SQL editor.
   This creates the private `meal-images` bucket, RLS policies, and RPCs.
2. Enable the Google provider in Supabase Auth using a Google OAuth web client.
   Use its matching Client Secret in Supabase, and set the public Web Client ID
   as `GOOGLE_WEB_CLIENT_ID` in `config.local.json`.
   Android uses Google's native account picker and exchanges its ID token for
   a Supabase session. In the same Google Cloud project, create an **Android**
   OAuth client for package `com.example.morsl` and the signing certificate SHA-1.
   For this machine's debug builds, that SHA-1 is
   `91:C4:32:91:67:61:48:08:79:92:BE:D0:70:6F:3F:44:21:EA:66:EF`.
   Register the production signing certificate separately before publishing.
   No Firebase project or `google-services.json` is required.
   iOS and desktop continue to use browser OAuth:
   Add Supabase's callback URL to the Google client's authorized redirect URIs.
   Add `com.morsl.app://login-callback` to Supabase's redirect allow list.
   Android and iOS register this callback scheme; desktop protocol registration
   is required separately for Windows sign-in. Disable email/password and anonymous
   sign-in for this app. Invitations require an existing account.
3. Create a free [Geoapify project](https://myprojects.geoapify.com/). Create separate
   keys for map tiles and server-side Places lookup. Deploy `supabase/functions/nearby-venues`:
   `supabase secrets set GEOAPIFY_PLACES_API_KEY=<server-key>` then
   `supabase functions deploy nearby-venues`. The function validates the caller
   with Supabase Auth and requires a non-anonymous Google account.
4. Configure your Geoapify keys and usage limits in its project dashboard. Map
   tiles use the public client key; Places lookup uses only the server key.
   The map displays clickable Geoapify and OpenStreetMap attribution.
5. Copy `config.example.json` to gitignored `config.local.json` and fill in the
   Supabase URL, **publishable/anon client key**, `GEOAPIFY_MAPS_API_KEY`, and
   `SEGMENTATION_URL`. Never put a Supabase service-role key or the server Places key in the app.
6. Run `flutter run --dart-define-from-file=config.local.json`.


No keys are checked in. Without service configuration, browsing examples remains
available. Capture and all changes require Google sign-in. The Map shows a labeled
illustration and local locations; cloud actions explain their configuration state.

## What is implemented

- Riverpod app dependency/state ownership; Drift/SQLite transactions and separate
  meal, asset, personal-memory, job, sync, evaluation, preference, and event data.
- Original photos in application documents, never large SQLite image blobs.
  Thumbnails are generated away from the UI thread. Imports use available EXIF
  capture dates/GPS and offer correction. Lost Android picker results are recovered.
- Separate plate masks, normalized source regions, independent placement, and
  content-addressed local PNGs. Backups preserve masks and rebuild the plate
  images from the original; existing single-cutout memories remain compatible.
- Cloud cutout adapter: processing and failure handling, with locally rendered
  masks and durable cutout storage.
  Interrupted jobs return to the queue at launch; originals remain editable.
- Plating: three presets, four paper backgrounds, normalized drag/scale/rotation,
  keyboard-accessible sliders, photo/cutout choice, reset, metadata, autosave, save.
- Chronological scrapbook, caption/venue/companion search, companion/date/repeat
  filters, bookmark, open/edit/archive; evening reminders scoped to the account,
  scheduled for unfinished drafts independently of AI completion.
- Confirmed map locations, Geoapify maps with meal clustering, memory pin opening, companion
  and repeat filters, offline list. Venue suggestions are live and user-confirmed.
  Only place IDs persist; user-entered labels and captured coordinates stay separate.
- Browse-only guest access and Google sign-in for actions. Account-scoped UI, records, files,
  and reminder preferences; content-addressed storage, persistent/coalesced sync
  operations, backoff/manual retry, revision conflicts and explicit resolution.
- Private meal invitations, acceptance/decline, independent recipient annotations,
  leaving, uploader photo removal, personal archive, and confirmed creator deletion.
  Revocation is checked before asset restoration and purges app-managed local caches.
  Deleted meals retain a server tombstone to prevent stale-device resurrection.
- Cutout comparisons, quality/failure labels, timings, runtime details,
  processing and backup queue status, JSON evaluation export.
  Local events include editing duration, revisits, sync failures, and restoration.

## Verification

```powershell
flutter analyze
flutter test
flutter build apk --debug
node --test supabase/functions/nearby-venues/handler.test.mjs
```

`test/data_test.dart` verifies persistence/reopen, exact transforms, job recovery,
original fallback, concurrent editing during extraction, account isolation,
backup interruption/idempotency, and acknowledgements of older queue operations.
`test/widget_test.dart` exercises search/navigation, saving after AI failure, and
renders 375×812, 812×375, and 1440×1000 previews with real photos and fonts.
It also checks Geoapify meal markers, visible attribution, and the offline view
using local test tiles. Venue endpoint tests cover Google account requirements,
coordinate validation, Geoapify's longitude-first parameters, response mapping,
and failed or timed-out provider requests.

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

No public feed, restaurant ranking, or automatic dish naming.
Processing is active-app work with launch recovery, not a promise of
execution after termination. Background workers can be added after device testing.
Guest browsing does not upload photos. Signed-in automatic extraction uploads
photos to Modal only after explicit consent, remembered per account and device.
Account backup is separate. Legacy guest memories can be associated after Google sign-in.
JSON beta exports contain IDs and runtime details; export is a deliberate user action.

Storage paths are immutable content addresses. An interrupted upload may leave
an unreferenced object; these are inaccessible to other participants. Before a
larger rollout, schedule server cleanup for unreferenced versions and assets of
deleted meals. Configure server-side venue quotas/rate limits and the project's
privacy policy/terms URL. The APK uses debug signing and is for beta testing;
store distribution needs your signing configuration.

Technical references: [cloud segmentation architecture](modal_architecture.md),
[Geoapify map tiles and attribution](https://apidocs.geoapify.com/docs/maps/map-tiles/),
[Supabase database RLS](https://supabase.com/docs/guides/database/postgres/row-level-security),
[Storage access](https://supabase.com/docs/guides/storage/security/access-control).
Fonts are bundled with OFL licenses. Photo sources are in `docs/assets.md`.
