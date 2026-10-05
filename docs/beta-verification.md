# Beta verification

Implementation and local automated checks exist. The full physical-device and
real-account journey is **not yet signed off**. No physical phones or connected
Supabase/Google project were available in the implementation environment.

## Local automated evidence

- Flutter analyzer: clean; Android debug APK built.
- Automated results: 18 Flutter tests and 22 PostgreSQL-compatible backend checks.
- Flutter tests: database reopen, composition persistence, interrupted extraction,
  safe failure, concurrent editor changes, explicit association/account scoping,
  interrupted sync retry, stable identity, and newer-operation preservation.
- Widget tests: search and primary navigation, saving with failed extraction,
  rendered phone/landscape/desktop layouts.
- PostgreSQL-compatible tests: migration compilation, idempotent writes, revision
  conflicts, pending-invitation privacy, accepted membership, separate annotations,
  creator-only shared details, personal archive, decline, unauthorized writes,
  leave/revoke, creator deletion, deletion tombstones, anonymous RPC denial.
- Android debug build: successful with native plugins. iOS build needs a Mac.

## Physical-device journey

Run on a physical Android device with Google Play services, and an iOS 17+ device
if that platform is in the beta. Use two real accounts and a second restoration
device. Repeat the cutout fallback path on an unsupported runtime too.

| Step | Action | Pass condition |
|---|---|---|
| 1 | Prepare model while online | Model readiness appears; a later offline job needs no model download |
| 2 | Capture in airplane mode | Saved-for-later appears before GPS/extraction; original is durable |
| 3 | Kill/reopen during processing | Draft remains intact; interrupted job resumes or safely fails |
| 4 | Rate cutout | Original/cutout compare, duration and device details; rating/category export |
| 5 | Compose/save offline | Paper, caption, feeling, companions, repeat flag and exact transforms survive reopen |
| 6 | Reconnect/confirm venue | Several candidates in dense building; own label/coordinates confirmed; provider content not persisted |
| 7 | Back up; interrupt upload | Pending status persists; reconnect/manual retry gives one memory and complete assets |
| 8 | Invite account B | Pending invitation reveals no asset rows or Storage images |
| 9 | B accepts and edits | Meal enters B history; layouts/captions are independent |
| 10 | Rediscover | Caption/companion/venue search, date/repeat filters, clustered map pins open correct memory |
| 11 | Restore A elsewhere | Complete authorized original/cutout/thumbs and exact personal composition restored |

Also test denial of camera, location and notification permissions; gallery EXIF
with and without timestamps/GPS; empty history; no coordinates; inaccurate GPS;
multiple venues in one building; unavailable Places; offline map; model download
failure; no subject; save while extraction runs; logout/account switch with an
editor open; accepted member leaving; decline/reinvite; photo removal; creator
meal deletion; and revocation while a different asset fails to download.

Simultaneous edits on two devices should create a visible backup conflict.
Beta notebook → Review must show the versions and require an explicit choice.
A newer local edit made during an in-flight backup must remain pending.

## Metrics

Beta notebook → Export evaluations creates an account-scoped JSON file. Inspect
cutout usability/failure categories and durations, editor finish durations,
`memory_opened` revisits, `sync_failed`, and `memory_restored` events. Exclude
example memories (`demo`) from behavior analysis. Testers should record whether
restoration had every asset and whether they returned to saved meals.

## Release gates

Do not mark milestone G complete until the journey above passes on the actual
backend and supported physical devices. Connect Auth/Storage/Maps/Places, deploy
migrations/functions, test RLS through live HTTP, add project privacy/terms URLs,
set service quotas, select final app IDs/signing, and establish storage cleanup.
