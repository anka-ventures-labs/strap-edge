# Push a digest to Strap Hub

Edge can send a schema 1 digest to a self-hosted Strap Hub after a completed
WHOOP history sync. The feature is off until a Hub URL and bearer token are
saved. There are no Hub settings screens in this change.

## Configuration API

Use `HubPush.instance.setConfig(url: ..., token: ...)` with the Hub's HTTPS
origin and bearer token. Edge posts to `/v1/digest` on that origin. The phone
must be able to reach the Hub over its tailnet. The URL lives in
`SharedPreferences`. The token lives in `FlutterSecureStorage` and is readable
after the phone's first unlock so background sync can use it.

`HubPush.instance.pushNow()` requests a delivery and returns a
`HubPushResult`. It honors any saved retry deadline. Use
`HubPush.instance.clearConfig()` to turn off pushes and clear the local
delivery state. Delete Everything also clears this configuration. Manage
copies already delivered to the Hub on the Hub itself.

## Contents and timing

The first acknowledged digest covers up to 30 local calendar dates, including
today. Later digests include today's data and each changed day, night, or
workout, including edits to older history. Edge reads the numeric
`metric_series`, the served `v_hypnogram` and public `v_sessions` views, and
the durable band record frontier. Dates follow the phone's local calendar.
Timestamps use ISO-8601 UTC. The payload includes only the contract's
summary fields. A missing band frontier is represented by null.

The shared BLE completion marker schedules the push through the next
successful derivation pass. This covers foreground, kept-alive background,
headless restore and background wakes, and Shortcuts Sync Data. Push work is
unawaited. If the OS suspends a background wake, a later sync can deliver the
latest snapshot. Derived changes written after the snapshot are eligible
on the next push.

## Delivery state and workout privacy

One record in the existing SQLite `sync_cursor` table holds the destination
fingerprint, acknowledged item fingerprints, retry deadline, and previously
sent workout IDs. Payloads are rebuilt from the live database on each attempt.
When a sent workout is made private or deleted, the next digest sends its ID
in `revoked_workout_ids`. Workout IDs and attempted revocations are
checkpointed before each POST so a lost response can be recovered. A workout
made public again can be sent again so the Hub clears its tombstone.

Only HTTP 200 advances the acknowledged fingerprints. Network failures and
HTTP 5xx use exponential backoff with one short retry at the start of an
outage and carry longer retry deadlines into later syncs. HTTP 401 preserves
the pending changes. Other
HTTP 4xx drop that payload and log its status; an identical payload is
suppressed until its content changes. Requests do not follow redirects.
Delivery logs omit the destination, bearer token, and payload.

## Verification

`test/hub/` contains SQLite FFI and mock transport tests for projection,
incremental delivery, privacy revocation, authentication, and retries. Run
`flutter analyze` and `flutter test test/hub` on a Flutter-equipped runner.
