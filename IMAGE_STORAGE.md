# Private R2 image storage

morsl uses Supabase for authentication, meal metadata, invitations, and permissions.
Image bytes use **Cloudflare R2 Standard only**. There is no Supabase Storage image
fallback or migration of older image records. Use a fresh Supabase project/database
and fresh app installation for this version. Do not reset a project with data you
need to retain.

## Activate storage

1. Create an **empty**, private **Standard** R2 bucket (for example `morsl-images`). Keep public
   access disabled. Create an R2 S3 API token with Object Read & Write permission
   restricted to that bucket.
2. In the Supabase project's Edge Function secrets, add these server-only values:

   ```text
   R2_ACCOUNT_ID
   R2_BUCKET
   R2_ACCESS_KEY_ID
   R2_SECRET_ACCESS_KEY
   ```

   `R2_BUCKET` is the bucket's name. `R2_ACCOUNT_ID` is your Cloudflare account ID.
   The keys are the S3 access key ID and secret access key, not a general Cloudflare
   API token. Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and
   `SUPABASE_SERVICE_ROLE_KEY` to the deployed function automatically. Never put
   R2 keys or the service-role key in the Flutter app or `config.local.json`.
3. Apply both migrations to the fresh Supabase database: the meal schema and
   `20261007012718_image_storage_quota.sql`. Configure Google sign-in as described
   in README.md. The quota migration is required before any upload can be signed.
4. Deploy the endpoint from this project directory:

   ```powershell
   supabase functions deploy image-storage --project-ref YOUR_PROJECT_REF --no-verify-jwt
   ```

   The function verifies the bearer token itself using Supabase Auth `getUser()`
   and checks the server-managed Google provider and meal permissions before
   signing any URL. `--no-verify-jwt` disables only the gateway's legacy JWT check;
   the endpoint still requires a valid authenticated Google account.
5. Point `config.local.json` at the fresh Supabase project and build/run Flutter
   with `--dart-define-from-file=config.local.json`. No R2 setting is needed on the
   device. Native mobile HTTP requests do not need browser CORS rules.

## Storage behavior

- Imported originals, thumbnails, and newly rendered cutouts start in the app's
  documents directory. They remain durable while uploads, processing, or edits are
  pending. Upload failure never makes these files eligible for cache eviction.
- Backup uploads originals, thumbnails, and finished plate PNGs to R2, then commits
  their object keys to Supabase. Cutouts are at most 1600 pixels on their longest
  edge and use lossless PNG compression with transparency preserved. Uploads are
  limited to 20 MiB each.
- The server enforces **9 GB (9,000,000,000 bytes) globally**, including uploaded
  objects and pending reservations across every account. Allocation locks one
  database budget row, so simultaneous uploads cannot each consume the same free
  space. Retries of the same object key/size reuse their reservation. The server
  verifies R2's actual object size before the app commits a backup. At capacity,
  new uploads stop with “Cloud storage is full”; local photos remain saved and
  queued for retry. Reading existing backups continues.
- Restoring retrieves metadata and stable object references, with **no image
  downloads and no cutout regeneration**. After a successful committed restore,
  backed-up document files are removed only when no pending edit/job or active
  editing tool needs them.
- Viewing downloads only the requested image. Opening selection/edge tools fetches
  the original and holds a cache lease until the tool finishes. Exports fetch the
  cutouts they need. Originals and cached cutouts outside the cache need internet.
- Replaceable cloud images live under the OS temporary directory in `morsl-images`,
  with a shared 100 MiB least-recently-used disk budget. Active leases can briefly
  exceed that budget; trimming runs as leases close and at startup. Unsynced imports,
  bundled examples, editable creations, and user exports are separate from this
  budget. The total app footprint can exceed 100 MiB while uploads are pending.
- Cache keys include the signed-in account. Account changes clear Flutter's decoded
  image cache; a successful membership revocation check also removes that meal's
  cached images. The OS may discard temporary cache files at any time.
- Signed R2 URLs expire after five minutes and are never saved as image references.
  Upload signatures bind the image type and byte length. Original uploads require
  creator access; plate uploads require membership and the caller's own folder.
  Downloads require current referenced assets, not just a guessed object key.
- Owner cleanup runs at most daily during sync, preserving all members' referenced
  cutouts and allowing 24 hours for uncommitted uploads. Photo removal and meal
  deletion also request cleanup immediately; daily cleanup retries failures.
  Quota stays charged until R2 acknowledges deletion, and cleanup waits at least
  24 hours after the last upload grant expires. Missing objects from abandoned
  uploads are also deleted idempotently before releasing their reservation.
  A failed delete retains its reservation. Cleanup blocks new grants for an
  object while deleting it. A crashed cleanup can leave a charged `deleting`
  entry: investigate the function logs and ensure the old invocation has ended
  before resetting that flag with a service/admin connection and retrying cleanup.

To inspect the shared budget in the Supabase SQL editor:

```sql
select used_bytes, 9000000000 - used_bytes as available_bytes
from public.image_storage_budget;
```

These tables and quota functions are service-only; devices cannot change the
budget. Use this bucket exclusively through the endpoint. Manual uploads, other
buckets, and other writers bypass this app's ledger. Do not clear the ledger or
reset its counter while objects remain in R2.

The free R2 allowance is shared across the entire app, not per user. Monitor storage
and operation usage in Cloudflare; the 9 GB cap limits app storage, but does not
cap billable read/write operations or guarantee a zero bill for the account.
Cleanup runs when an owner syncs, so an inactive owner does not trigger daily cleanup.

## Verify before release

Use two accounts and a real private R2 bucket to check upload, reinstall/restore,
editing after cache eviction, export, invitation acceptance, membership revocation,
and image/meal deletion. Restore should issue only metadata requests until an image
is actually displayed. Confirm that a URL expires and that an unrelated account
cannot obtain a signed URL. Check function logs without logging signed URLs or keys.

Local automated checks cover cache budget/leases, interrupted downloads, cloud
reference restore, upload ordering/failures, and signing authorization. They do not
replace live R2 and two-account verification.
