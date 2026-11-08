# Footage Review local API

Footage Review exposes detected appearances and accepts reviewed group assignments from another application. Imported groups appear in the app’s Groups sidebar, and their membership and notes are saved in the review library.

## Connect a client

1. Open **Footage Review → Settings → Integrations**.
2. Choose a port, then click **Start API**. The default port is `8765`.
3. Copy the endpoint and access token into your client.
4. Keep Footage Review open while the client uses the API.

The server binds to `127.0.0.1`. Each request uses `Authorization: Bearer <token>`. The app creates the token when starting the API, so copy the current token after restarting it. API responses and exported images contain review-library data.

For a browser frontend, enter its origin in **Browser origin** before starting the API. For example, `http://localhost:3000` allows that exact origin. Origins include the scheme, hostname, and port. Leave the field blank for a native or command-line client. A matching-origin browser OPTIONS preflight is allowed without a token and returns 204; all data requests still require the bearer token.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | Check API availability. |
| `GET` | `/v1/groups` | Read the library identifier, current revision, and groups. |
| `GET` | `/v1/appearances` | Export a page of appearances with crop images and clip metadata. |
| `POST` | `/v1/group-imports` | Apply human-reviewed group assignments. |

All JSON keys use `snake_case`. Identifiers are opaque stable values. Preserve them exactly in returned assignments. An appearance ID identifies a detection at a clip offset; a reviewed group can contain many appearances of the same person.

## Inspect an export

The following examples use a token entered into the shell without echoing it. The endpoint can be copied from the app.

```bash
API_ENDPOINT=http://127.0.0.1:8765
read -r -s API_TOKEN
export API_TOKEN
printf '\n'

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $API_TOKEN" \
  "$API_ENDPOINT/v1/groups"

curl --fail-with-body --silent --show-error \
  -H "Authorization: Bearer $API_TOKEN" \
  "$API_ENDPOINT/v1/appearances?limit=20"
```

The appearances endpoint accepts `date`, `source`, and `camera` filters. A date uses the displayed `YYYY-MM-DD` form. Source and camera values match the app’s metadata. URL-encode query values that contain spaces or punctuation.

The page size defaults to 20 and accepts limits from 1 through 50. Follow the returned cursor to request subsequent pages. A cursor belongs to a fixed export snapshot that expires 30 minutes after creation. Availability can end earlier: the fifth live snapshot evicts the oldest, and restarting the API discards all snapshots. The server retains up to four snapshots. A client should finish a snapshot while it remains available, then start a fresh export when needed. Each response is limited to 8 MiB, and an exported JPEG can contain up to 512 KiB.

Crop images are JPEG bytes encoded as base64 within the JSON export. The client can decode these bytes for display while preserving each appearance identifier for reviewed assignments.

## Export response schema

`GET /v1/health` returns `status`, `library_id`, and `revision`. `GET /v1/groups` returns `library_id`, `revision`, and an `items` array containing `id`, `name`, `note`, and `appearance_ids` for each group.

An appearance page has this shape.

```json
{
  "library_id": "<library-id>",
  "revision": 7,
  "snapshot_id": "<snapshot-id>",
  "total": 42,
  "items": [
    {
      "id": "<appearance-id>",
      "clip_id": "<clip-id>",
      "source": "Blink",
      "camera": "Frontdoor",
      "date": "2026-05-25",
      "clock": "08:57:46",
      "seconds": 4.0,
      "confidence": 0.98,
      "group_ids": [],
      "image": {
        "mime_type": "image/jpeg",
        "base64": "<base64-encoded-JPEG>"
      }
    }
  ],
  "next_cursor": "<opaque-cursor-or-null>"
}
```

`seconds` is the appearance’s offset within its source clip. Date and clock values use the clip metadata displayed by the app. `total` is the number of items in the export snapshot. The last page has `next_cursor: null`. A response can contain fewer items than `limit` to fit the response size bound. Keep requesting `next_cursor` until it is null.

For a subsequent page, URL-encode `next_cursor` and pass it as `cursor`. The snapshot preserves the original filters. Additional filters must match those supplied on its first page.

### Python example

This standard-library example reads one page, saves its JSON, decodes its first JPEG, and opens that image using the Mac’s default application. Enter the access token at the hidden prompt.

```python
import base64
import getpass
import json
from pathlib import Path
import subprocess
from urllib.request import Request, urlopen

endpoint = "http://127.0.0.1:8765"
token = getpass.getpass("API token ")
request = Request(
    endpoint + "/v1/appearances?limit=20",
    headers={"Authorization": "Bearer " + token},
)
with urlopen(request, timeout=10) as response:
    page = json.load(response)

Path("appearance-page.json").write_text(json.dumps(page, indent=2))
if page["items"]:
    first = page["items"][0]
    image = Path("first-appearance.jpg")
    image.write_bytes(base64.b64decode(first["image"]["base64"], validate=True))
    subprocess.run(["open", str(image.resolve())], check=True)
```

## Return reviewed groups

Reviewers use the exported appearance identifiers to label their selected groups. A submitted group supplies its complete desired name, note, and membership. Sending fewer appearance IDs removes the omitted memberships from that group; an empty array clears its membership. Omitting a note resets it to an empty string. The server updates only the groups supplied by the request, and other groups remain in the library. Membership is not exclusive: an appearance may belong to more than one group.

Use the `library_id` and revision from `/v1/groups`. Keep the revision associated with the group state the reviewer has checked. An import is applied atomically after all group names, identifiers, appearance references, and the library revision validate. An Edit Group sheet also checks its original group before saving. If an import changes that group while its editor is open, reopen the editor to review the updated values before saving.

Example request body, with placeholders replaced by values from the current library and export, is shown below.

```json
{
  "import_id": "30edf0f8-f4e9-4813-a6b3-9b917ce2ca0e",
  "library_id": "<library-id-from-export>",
  "base_revision": 7,
  "reviewer": "Reviewer name",
  "groups": [
    {
      "id": "56844acf-7c78-4fba-967d-8ad436aa45c2",
      "name": "Frontdoor review",
      "note": "Reviewed appearances for the selected dates.",
      "appearance_ids": [
        "<appearance-id-from-export>",
        "<another-appearance-id-from-export>"
      ]
    }
  ]
}
```

`reviewer` and each group’s `note` are optional. `library_id`, `import_id`, and each group `id` must be UUIDs. Use a new UUID for a new group and preserve its UUID on later updates. Use a new `import_id` for each intended update. Save the request as `reviewed-groups.json`, then submit it.

```bash
curl --fail-with-body --silent --show-error \
  -X POST \
  -H "Authorization: Bearer $API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @reviewed-groups.json \
  "$API_ENDPOINT/v1/group-imports"
```

Successful application and replay both return HTTP 200. The response includes `import_id`, the import’s resulting `revision`, the latest `current_revision`, updated `group_ids`, an `appearance_count`, and `replayed`. `appearance_count` counts distinct appearance IDs across all submitted groups. The app also displays a short import result in Integrations.

Each import accepts 1–100 groups and up to 10,000 supplied appearance assignments before deduplication. Group names must contain 1–120 characters after trimming; notes accept up to 4,000 characters and the reviewer label up to 200. The body must fit within 2 MiB.

## Retries and conflicts

An accepted import is recorded durably. Retrying the same `import_id` and request returns its recorded result, including after the app restarts. The replayed response has `replayed: true`. A replay can report a newer `current_revision` if other changes have since been applied.

| Status | Meaning | Client action |
| --- | --- | --- |
| `400` | Query parameters, JSON, or the import schema are invalid. | Correct the request using the returned error code and message. |
| `401` | Authentication failed. | Copy the active token from Integrations and retry. |
| `403` | The browser origin or requested CORS headers are rejected. | Match the origin configured in Integrations. |
| `409` | The library revision changed, or an import identifier was reused with a different request. | Read the error, refresh current groups, review the changed state, and prepare a new request when appropriate. |
| `410` | The export snapshot expired or was evicted. | Begin a new export without a cursor. |
| `413` | A request or response exceeds its size bound. | Keep import bodies within 2 MiB and use a smaller export page when needed. |
| `415` | The import has an unsupported content type. | Send `Content-Type: application/json`. |
| `422` | An appearance reference is unavailable or a requested crop failed validation. | Refresh the affected appearances or repair the scan/crop, then retry the intended request. |

Errors return JSON with `code` and `message` fields. A `503` response can indicate that the library is restoring, a save failed, or the server has too many active requests. Retry a failed save with the same import identifier and request after resolving the local error. The HTTP server applies a ten-second request deadline.

A revision conflict preserves the current groups. Fetch them again and reconcile the reviewed assignments before changing `base_revision`. Generate a new import identifier when intentionally changing the submitted assignments.

## A review workflow with friends

1. Export the appearances and current groups with your local client.
2. Give the exported review data to a reviewer through your chosen sharing method.
3. Have the reviewer return group names, notes, and the original appearance identifiers.
4. Review the returned assignments in your client, then submit the import to the local API.
5. Open the resulting group in Footage Review to inspect its appearances and source clips.

The endpoint operates on the current review library. Its identifiers keep reviewed assignments tied to the same clips and detections.
