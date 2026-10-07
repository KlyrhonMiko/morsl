# morsl

**Little bites. Our little history.**

A native Flutter beta centered on a library of plate cutouts. Sign in → add a meal
photo → cut out individual plates → Library. Each plate keeps its restaurant, time,
and companions, plus an independent 1–5 star rating and optional note. Choose any
plates from the library to arrange into one photo; save an editable creation or
export a 1600 × 1600 PNG. Arrangements are saved on this device, separately from
source meals. Every new capture or import stays in Drafts, including after cutouts
are ready, until the user chooses **Finish & save**. Capture returns to Drafts with
an **Edit now** shortcut; users can eat first and return to edit later.

## Run the local beta

```powershell
flutter pub get
flutter run -d <your-android-device-id>
```

Automatic cutouts use the cloud segmentation endpoint on Modal and require an
internet connection and Google sign-in. Cloud cutouts are enabled by default;
an explicit opt-out in Settings is remembered per account on this device.
No local model download is required. Meal photos are uploaded for processing.
Each detected dish gets its own
transparent mask and independent placement.
Automatic dish masks retain food inside the dish outline. Enclosed gaps are
filled; sparse or photo-edge-clipped rims use a convex outline fallback.
Automatic extraction also runs a `food` prompt on the same encoded photo.
Only dishes with meaningful food overlap inside their completed outline are
kept; empty plates, utensils-only plates, and incidental empty rims are omitted.
Narrow slivers at the photo border are rejected before outline completion,
and smaller masks contained within a full dish are suppressed even when their
confidence is higher. Food-filled dishes may still touch the photo edge.
Small dishes clipped at two adjacent photo edges are omitted when their visible
mask is at most 12% of the photo and at most a quarter of the largest serving.
This composition filter also applies to food-filled background bowls. Fully
visible sides, dishes clipped at only one edge, and the largest dish survive.
Masks within 0.3% of the photo edge count as clipped to allow small model gaps.
Serving boards with food directly on them are detected separately and saved as one serving,
including meat and bowls resting on the board. Bowls or food extending slightly
beyond its edge are retained; nearby dishes stay separate. Empty boards still
require food evidence and are omitted. Food contained entirely in bowls cannot
promote a surrounding table or board into a combined serving; those bowls stay
separate. This depends on SAM3 recognizing the board and food correctly.
If food is missed (for example pale food or soup), automatic extraction may
omit its dish; **Select a plate** remains available for manual recovery.
Detections smaller than 1% of the uploaded image are omitted to reduce tiny
background dishes and screenshot gallery thumbnails. Very small dishes or
irregular, overlapping outlines may still need the manual edge tools.
New imports run this automatically. Manual cleanup afterward can refine edges
or add a missed plate; it also provides recovery when cloud processing fails.
Multi-photo imports process each source independently on the same segmentation
service. A failed first photo keeps the meal in a failed state even if later
photos succeed. Manual retry processes failed sources while retaining successful
cutouts. Busy responses (HTTP 429, rejected before GPU inference) receive one
automatic retry after the server's cooldown, up to 60 seconds. Timeouts and
inference errors are left for manual retry to avoid duplicate GPU work.
For older merged results, **Separate dishes**
in Meal details replaces the current cutouts in one step. It can reset existing plate
positions and edge edits, so use it when you want to regenerate them.

Recognition is not guaranteed for every photo, and parts outside the photo or
behind another dish cannot be
reconstructed. Optional **Select a plate** and **Edit edges** tools remain for
corrections and work offline. See [cloud architecture](modal_architecture.md)
for the current deployment script and client integration.

First launch includes clearly labeled example memories and an example draft.
Saved examples include bundled transparent food cutouts from their source photos;
existing examples are upgraded in place. Newly captured meals generate cutouts
automatically and keep them in Drafts until **Finish & save** adds them to the
plate library. **Edit later** saves changes and keeps the meal in Drafts.
Original photos remain as source
material for edge corrections; there is no original/cutout or layout selector.
Bundled examples stay local and never upload. Google sign-in is required for camera,
import, manual editing, bookmarks, sharing, exports, and changes to settings. Guests
can browse and search the example scrapbook. Camera and import
create real meals. Windows has an import/editor fallback; its runner requires
Visual Studio's C++ workload. This project is a native mobile app, not a web app.

The test APK is `build/app/outputs/flutter-apk/app-debug.apk`.
Rendered UI previews are in `output/previews/`.

## Connect backup, invitations, and maps

1. Create a fresh Supabase project. Apply
   `supabase/migrations/202610050001_beta.sql` using the Supabase CLI or SQL editor.
   Apply subsequent migrations too, including `20261007052824_friends.sql` for
   mutual friend requests. Find Friends in Settings or the meal invitations inbox;
   accepted friends can be selected under “Who was at the table?” to invite them
   to the whole meal and all its plates. A meal invitation still requires acceptance.
   This creates meal metadata, RLS policies, and RPCs. Images now use private
   Cloudflare R2; follow [image storage setup](IMAGE_STORAGE.md) to create the bucket,
   set server secrets, and deploy `image-storage`. This fresh baseline does not
   create a Supabase Storage image bucket or provide an image-storage fallback.
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
- Original photos and finished cutouts stay in application documents after backup,
  never as large SQLite image blobs. Private R2 provides backup and recovery;
  owned meals restore missing images into permanent local storage. Shared images
  use a separate 100 MiB temporary cache and download on demand.
  Thumbnails are generated away from the UI thread. Imports use available EXIF
  capture dates/GPS and offer correction. Lost Android picker results are recovered.
- Separate plate masks, normalized source regions, independent placement, and
  content-addressed local PNGs. Backups preserve masks and rebuild the plate
  images from the original; existing single-cutout memories remain compatible.
- Cloud cutout adapter: processing and failure handling, with locally rendered
  masks and durable cutout storage.
  Interrupted jobs return to the queue at launch; originals remain editable.
- Plate library with individual cutouts, restaurant/time metadata, plate names,
  1–5 star food ratings, optional notes, and plate/restaurant search.
- Separate photo editor: select plates across meals, freely move/resize/rotate,
  reorder, add/remove plates, choose a background, save an editable local creation,
  and export a PNG. There are no layout presets or original/cutout selectors.
- Meal details and edge corrections autosave independently of arrangements;
  evening reminders are scoped to the account,
  scheduled for unfinished drafts independently of AI completion.
- Confirmed map locations, Geoapify maps with meal clustering, memory pin opening, companion
  and repeat filters, offline list. Restaurant-name search finds nearby branches
  around the photo's location or permission-based device location. Selecting a
  result fills the venue name and map coordinates; a typed name can also be saved
  without a pin. Deploy the updated `nearby-venues` function with app updates.
- Browse-only guest access and Google sign-in for actions. Account-scoped UI, records, files,
  and reminder preferences; content-addressed storage, persistent/coalesced sync
  operations, backoff/manual retry, revision conflicts and explicit resolution.
- Private meal invitations, acceptance/decline, independent recipient annotations,
  leaving, uploader photo removal, personal archive, and confirmed creator deletion.
  Revocation is checked before asset restoration and purges app-managed local caches.
  Deleted meals retain a server tombstone to prevent stale-device resurrection.
- Local processing records include timings and runtime details. Local events
  include editing duration, revisits, sync failures, and restoration.

## Modal timing logs

Dish cleanup uses SciPy's compiled hole filling with four-neighbour connectivity,
reuses candidate bounds, and computes row extrema with NumPy reductions. The
convex envelope fallback and dish filtering thresholds are preserved. A local
benchmark of six synthetic masks at 1600×1200 measured median cleanup times
of 1144 ms before and 90 ms after (three runs each); this is not a live Modal
measurement. The old and new masks and encoded responses matched exactly.

After deploying `modal/app.py`, search the API and GPU worker logs for
`"event":"sam3_timing"`. Each JSON line reports milliseconds in `total_ms`
and `stages_ms`, with `status` and an error type for failed operations.

- `snapshot_prepare`: imports, model loading, cache commit, and synthetic-image
  warmup before capturing the GPU snapshot. This runs when creating a snapshot,
  not on every restore. With snapshots disabled it is named `startup`.
- `worker_ready`: the hook after initialization or snapshot restore. It gives
  each worker a fresh `worker_id` and request counter. Its small `total_ms` is
  only hook time, not snapshot restoration or container provisioning time.
  `snapshot_id` links workers that share the captured model state.
- `segment`: image decoding, image encoder, each plate/bowl/food-tray/serving-board/food prompt,
  transfers to CPU, mask cleanup, and mask encoding (including deduplication).
  `first_request` identifies the first extraction on a worker.
- `remote_call`: API-to-worker elapsed time, including queueing, any cold
  start, processing, and result transfer. Match its `request_id` to `segment`.

Compare first requests with later requests to distinguish startup overhead
from processing costs. GPU stages synchronize CUDA at their boundaries for
accurate measurements; this adds some profiling overhead. These timings do
not include billed idle time, the client upload, or authentication, and are
not a bill calculation. Logs contain no photos or authentication tokens.
The extraction response format is unchanged.

## Testing Modal snapshots

GPU snapshots are enabled in `modal/app.py`. Model loading and warmup occur in
`@modal.enter(snap=True)`; per-worker counters initialize in the hook with
`snap=False`. Warmup uses only a synthetic image and its features are discarded
before capture. This uses Modal's experimental GPU snapshot feature; live
compatibility and the speed improvement must be measured after deployment.

1. Run `modal deploy modal/app.py`, then extract a known plate photo in the app.
   The first invocation may take longer while Modal creates a snapshot.
2. Check the GPU worker's Containers tab for snapshot creation/restoration
   indicators, or logs for `Snapshot created. Restoring Function from memory snapshot.`
3. Wait until the GPU worker has stopped (normally allow at least two minutes
   without requests; confirm it is stopped in Modal), then process the same photo.
   A new `worker_id` and `first_request: true` establish that this is a new worker;
   the Modal restore indicator establishes that it used a snapshot.
4. Repeat at least three cold requests, waiting for shutdown between each.
   Modal may create 2–3 GPU snapshots for different worker hardware, so distinguish
   creation runs from restore runs. Do not redeploy between requests: deployment
   changes invalidate existing snapshots.
5. Compare the median `remote_call.total_ms` for confirmed restore runs with
   the previous 28–38 second cold calls. Also check total HTTP duration, successful
   responses, plate count, and cutout quality. Test several photos after restore
   to check that warmup did not leave stale image features.
6. For a warm comparison, immediately repeat an extraction and check that
   `worker_id` is unchanged and `first_request` is false.

For rollback or a controlled baseline, set `GPU_SNAPSHOTS = False` in
`modal/app.py` and redeploy. Re-enable and redeploy to create new snapshots.
Snapshots can skip imports and first-use initialization, but restoring model
weights and acquiring a GPU can still take time. They do not keep a GPU running
all day. Reference: [Modal memory snapshots](https://modal.com/docs/guide/memory-snapshots).

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

The backend test uses PGlite (PostgreSQL in WASM) with mocked Supabase Auth
schemas and three synthetic identities. It tests actual SQL/RLS, not Dart mocks:

```powershell
npm install --prefix "$env:TEMP/morsl-postgres-verification" --no-audit --no-fund @electric-sql/pglite
node test/backend_security.mjs
```

This validates the migration and authorization/revision logic locally; it does
not replace real Supabase Auth, R2 HTTP access, or two-account device tests.
R2 authorization, transfer metering, and storage checks are in `supabase/functions/image-storage/`.
Physical-device cutout quality and live two-account service verification remain release gates.

## Scope and operational notes

No public feed, restaurant ranking, or automatic dish naming.
Processing is active-app work with launch recovery, not a promise of
execution after termination. Background workers can be added after device testing.
Guest browsing does not upload photos. Signed-in automatic extraction uploads
photos to Modal by default, unless disabled in Settings for that account and device.
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
