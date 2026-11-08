# Connect your review tool

**Footage Review 1.3 | API v1 | Quick reference | 8 November 2026**

Export detected appearances to another app, review and label them, then return group assignments. Imported groups and notes are saved in your review library and appear in the **Groups** sidebar.

## Start in Footage Review

1. Open **Footage Review → Settings → Integrations** (⌘,). Choose a port; the default is **8765**.
2. For a browser app, enter its exact **Browser origin**, such as `http://localhost:3000`. Leave it blank for a native or command-line client.
3. Click **Start API**. Wait for **Running on this Mac**, then copy the endpoint and access token into your client.
4. Keep Footage Review open. **Stop API** closes the listener. Starting it again creates a fresh token; copy the new one into your client.

The endpoint is local to this Mac: `http://127.0.0.1:8765` at the default port. It does not provide a connection from a friend's computer. Share exported review data through your chosen method, then import the reviewed result locally.

## Four data endpoints

| Method and path | Use it to |
| --- | --- |
| `GET /v1/health` | Check availability; read `status`, `library_id` and `revision`. |
| `GET /v1/groups` | Read `library_id`, current `revision` and group `items`. |
| `GET /v1/appearances` | Export appearances, clip metadata and JPEG crops in pages. |
| `POST /v1/group-imports` | Save human-reviewed group names, notes and membership. |

Every data request needs `Authorization: Bearer <token>`. Browser preflight (`OPTIONS`) is the sole unauthenticated exception and requires the configured origin. An allowed origin matches its scheme, host and port exactly; it does not remove token authentication.

## Know what the identifiers mean

An **appearance ID** identifies one detected appearance at an offset within a clip. It is not a person identifier or a unique-person count. A **group ID** identifies a human-reviewed group. Keep all exported IDs unchanged; use them to link review decisions to the same library and detections.

## Review with a friend

Export appearances and current groups → share that review data → receive names, notes and original appearance IDs → check the returned assignments → import locally → open the group in Footage Review and inspect its source clips.

This guide summarizes the implemented API. For full detail, use **API.md**, supplied with the Footage Review source. Examples use synthetic values and placeholders; replace every value in angle brackets.

<!-- PAGE BREAK -->

# Export appearances

First save `/v1/groups`: its `library_id` and `revision` tie the review to the current group state. Its `items` contain `id`, `name`, `note` and `appearance_ids`. Exported JSON keys use `snake_case`.

## Connect without displaying the token

Run these commands in Bash. Set the endpoint to the value copied from Integrations, then paste the current token at the hidden prompt.

```bash
API_ENDPOINT=http://127.0.0.1:8765
read -r -s -p 'API token: ' API_TOKEN; printf '\n'
export API_TOKEN
curl --fail-with-body -sS -H "Authorization: Bearer $API_TOKEN" \
  "$API_ENDPOINT/v1/groups" > groups.json
curl --fail-with-body -sS --get \
  -H "Authorization: Bearer $API_TOKEN" \
  --data-urlencode 'date=2026-05-25' --data-urlencode 'limit=20' \
  "$API_ENDPOINT/v1/appearances" > page-1.json
```

Optional `date`, `source` and `camera` filters are exact matches to displayed metadata. Use `YYYY-MM-DD` dates and URL-encode query values. `limit` defaults to **20** and accepts **1-50**.

## Read a page

```json
{
  "library_id": "<library-uuid>", "revision": 7,
  "snapshot_id": "<snapshot-uuid>", "total": 42,
  "items": [{
    "id": "<appearance-id>", "clip_id": "<clip-id>",
    "source": "Blink", "camera": "Frontdoor",
    "date": "2026-05-25", "clock": "08:57:46",
    "seconds": 4.0, "confidence": 0.98, "group_ids": [],
    "image": {
      "mime_type": "image/jpeg", "base64": "<JPEG-base64>"
    }
  }],
  "next_cursor": "<opaque-cursor>"
}
```

Decode `item["image"]["base64"]` as base64 JPEG bytes to display a crop. Preserve its `id` with the review decision. `seconds` is the clip offset; `confidence` is detector confidence, not confidence in a person's identity. Date and clock come from clip metadata, commonly parsed from filenames, and are not guaranteed capture times.

## Keep paging until the cursor is null

Copy the returned `next_cursor` into `CURSOR`, then fetch another page:

```bash
CURSOR='<next_cursor-from-the-previous-page>'
curl --fail-with-body -sS --get \
  -H "Authorization: Bearer $API_TOKEN" \
  --data-urlencode "cursor=$CURSOR" \
  "$API_ENDPOINT/v1/appearances" > page-next.json
```

The snapshot retains the first page's filters. Omit filters on later pages, or repeat their exact values. A page may be shorter than `limit`; continue until `next_cursor` is `null`. `total` counts appearances in that snapshot, not unique people.

<!-- PAGE BREAK -->

# Return reviewed groups

Use the exported `library_id` and the `revision` from the group state you reviewed. Replace the placeholders and save **reviewed-groups.json**. Run macOS `uuidgen` for each new import or group UUID; preserve the group's UUID on later updates.

## Request body

```json
{
  "import_id": "<new-import-uuid>",
  "library_id": "<library-uuid-from-export>",
  "base_revision": 7,
  "reviewer": "Reviewer name",
  "groups": [{
    "id": "<new-or-existing-group-uuid>",
    "name": "Frontdoor review",
    "note": "Reviewed for the selected dates.",
    "appearance_ids": ["<appearance-id>", "<another-id>"]
  }]
}
```

`import_id`, `library_id` and each group `id` must be UUIDs. Appearance IDs must be copied from the same library's export. `reviewer` and `note` are optional; omitting `note` sets that group's note to an empty string.

## Submit the complete membership

```bash
curl --fail-with-body -sS -X POST \
  -H "Authorization: Bearer $API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @reviewed-groups.json \
  "$API_ENDPOINT/v1/group-imports"
```

Each supplied group replaces that group's name, note and **complete membership**. Include every appearance you want to keep in it. An empty `appearance_ids` array clears its membership. Groups absent from the request are preserved. An appearance can belong to more than one group.

Validation and saving are atomic: the whole import is saved, or none of its changes are applied. Groups appear in the app's **Groups** sidebar; Integrations shows the import summary.

## Success: HTTP 200

```json
{
  "import_id": "<import-uuid>",
  "revision": 8, "current_revision": 8,
  "group_ids": ["<group-uuid>"],
  "appearance_count": 2,
  "replayed": false
}
```

`appearance_count` counts distinct appearance IDs across submitted groups. `revision` is the import's revision; `current_revision` is the library's latest. They can differ on a replay.

## Retry an uncertain result safely

Retry the saved request with the **same `import_id` and unchanged request** if a response is lost or a save needs retrying. Accepted imports survive app restarts; a replay returns HTTP 200 with `replayed: true`. Copy the new token after restarting the API.

A deliberate change needs a **new `import_id`**. If groups changed meanwhile, fetch `/v1/groups`, reconcile the assignments, then use the reviewed current revision. Do not change `base_revision` blindly to bypass a conflict.

<!-- PAGE BREAK -->

# Solve common problems

Errors return a JSON object with `code` and `message`. Read both before changing a request. A rejected import leaves the saved groups unchanged.

| Result | What to check or do |
| --- | --- |
| Cannot connect | Keep Footage Review open, start the API and use its copied endpoint. If the port is busy, choose another port in Integrations. |
| `400` Bad request | Fix query values, JSON, UUIDs or group field limits. Do not send a query key more than once. |
| `401` Authentication | Copy the active token. Send `Authorization: Bearer <token>` on every data request. |
| `403` Browser origin | Match the exact configured origin. A browser may request only the allowed methods and headers. |
| `409` Conflict | Read the code: wrong library, changed revision, duplicate group name or reused import ID with different assignments. Reconcile before submitting a new intended update. |
| `410` Snapshot gone | Start an export without `cursor`. Preserve reviewed IDs, but check them against a fresh export before import. |
| `413` Too large | Reduce an export page's `limit`, or keep the import body within 2 MiB. |
| `415` Content type | Send `Content-Type: application/json` with the import. |
| `422` Unavailable data | Refresh exported IDs for unknown appearances. For missing or invalid JPEG crops, inspect the library and affected clip in Footage Review. |
| `503` Unavailable | Let library restoration finish or retry a busy server. Resolve a reported local save error, then retry the same saved import. |

## Practical bounds

| Item | Current limit |
| --- | --- |
| Export paging | Default 20; 1-50 appearances per page. Response at most 8 MiB; each JPEG at most 512 KiB. |
| Export lifetime | Up to 30 minutes; at most four snapshots. A fifth evicts the oldest. API restart invalidates all cursors. |
| Import size | At most 2 MiB; 1-100 groups and 10,000 appearance assignments total per request. |
| Text fields | Trimmed name: 1-120 characters; note: at most 4,000; reviewer: at most 200. Group names must be unique. |
| Requests | Ten-second server deadline. Browser preflight allows GET, POST, OPTIONS and Authorization / Content-Type headers. |

## A reliable handoff

Give the reviewer the exported data and current groups together. Keep `library_id`, appearance IDs and group UUIDs with their work. Save the reviewed request before posting it. After success, open the imported group in Footage Review to check its appearances and clips.

The API exports existing detections and accepts human-reviewed labels. It does not start scans, infer identities or count unique people. The images and metadata are review-library data; share only the exports you intend to share.

**Detailed reference:** **API.md**, supplied with the Footage Review source. This quick reference describes Footage Review 1.2 / API v1 as checked on 8 November 2026.
