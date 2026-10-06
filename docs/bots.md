# Bot integration

An administrator creates a bot under People & settings → Bots & integrations,
then adds it to a private room or opens a direct ping. Bots automatically belong
to open rooms. The management dialog shows its key and supports key rotation,
name/avatar changes, and an optional webhook URL. Account deactivation disables it.

Let `BASE` be `/api/bot/KEY/rooms/ROOM_ID/messages`:

| Request | Behavior |
| --- | --- |
| `GET BASE` | Latest 40 messages in chronological order |
| `GET BASE?before=ID` / `?after=ID` | Adjacent history page |
| `POST BASE` | Send a message or attachment |
| `PATCH BASE/ID` | Edit a message sent by this bot |
| `DELETE BASE/ID` | Delete a message sent by this bot |
| `POST BASE/ID/boosts` | Add a boost |
| `DELETE BASE/ID/boosts/BOOST_ID` | Delete this bot's boost |

History responses include `X-Total-Count` and a `Link` header when another page
exists. Keys cannot impersonate a human, access a room without membership, or
edit another sender's messages. The ordinary session API does not accept bot keys.

Message bodies accept `text/plain`, sanitized `text/html`, or
`application/json` with `{"body":"<p>Hello</p>","client_id":"unique-send-id"}`.
Keep `client_id` stable when retrying a send. Uploads use `multipart/form-data`
with an `attachment` or `file` field, up to 16 MiB. Boosts accept plain text or
`{"content":"Nice!"}`, limited to 16 Unicode characters.

## Webhooks

A human mentioning the bot in a room, or sending in a direct conversation with
it, queues a POST to the configured webhook. Bot-generated messages do not
recursively trigger callbacks.

```json
{
  "user": {"id": 2, "name": "Casey"},
  "room": {"id": 3, "name": "Planning", "path": "/api/bot/KEY/rooms/3/messages"},
  "message": {
    "id": 42,
    "body": {"html": "<p>Hello</p>", "plain": "Hello"},
    "path": "/rooms/3?at=42"
  }
}
```

Returning HTTP 200 with `text/plain` or `text/html` posts a reply. Other nonempty
content types post a file. Empty responses and other non-error 2xx/4xx statuses
produce no reply; 5xx responses retry through the job queue. Responses, runtime,
and download sizes are bounded. This is Vampfire's API, not Rails wire compatibility.
