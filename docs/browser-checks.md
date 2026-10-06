# Browser checks

The V main update to `1b4ecb9` was checked in local headless Chromium 153 with
Playwright 1.63.0 after the collaborative preview host reported it was unavailable.
Both apps passed sign-in, 40-message room views, history, and 13 search matches.
V also delivered three messages between two browser users, including a 4 KiB
Unicode message followed by a short message. WebSocket receipts and rendered
messages were checked; no JavaScript errors or failed local responses occurred.
[Updated V evidence](validation/20261006-main-1b4ecb9/vampfire-browser.json) ·
[Rust evidence](validation/20261006-main-1b4ecb9/rust-browser.json).

## Initial feature checks

Checked in the collaborative Chromium browser on 2026-10-06, using fictional
Alex Example and Casey Example accounts. Network requests exercised the running
V server and real SQLite storage. Browser fixtures were kept separate from all
integration and benchmark databases.

| Check | Observed result |
| --- | --- |
| Fresh setup and room creation | Workspace and All Talk created; message survives reload |
| Second user | Another user's WebSocket message appears live; boost can be added |
| Historical permalink and newer page | 41 initial messages, then 81 after loading newer |
| Reconnect in history | Visible message ID 77 remained the anchor after reconnect |
| Send from history | Returned to latest history; sent message visible; editor focused |
| Search pagination | 40 then 80 results; all IDs unique |
| Search actions | Add/remove boost; delete removes both result and room link |
| File queue | Image visible before send; no premature message; upload creates message |
| Image lightbox | Original loads in dialog; Escape closes it |
| Audio and video | Both reach readyState 4 and advance during muted playback; processed video poster loads |
| Table | Configurable table survives server sanitization; adding a row changes 2 rows to 3 |
| Rich paste | Bold/italic retained; script, event handlers, image handlers, and javascript: links removed |
| Code | 17-language chooser; Rust keyword and string highlighting survives message save |
| Profile | Bio saved in profile form |
| Session transfer | QR/link created; logout returns to sign-in; one-time link signs in successfully |
| Mention spacing | Named/numeric HTML entities render as text instead of literal entity strings |
| Mentions | `@Case` offers Casey; Enter inserts a mention without sending |
| Public link | Pasted example.com URL becomes a link and a fetched preview card |
| Workspace settings | Form saves successfully in a 358px-wide mobile dialog |
| Mobile dark mode | 390×844; document width 390px; sidebar and composer usable |
| Invitations | Link and actual QR SVG shown |
| Bots | Bot created through management form |

The browser work caught issues that the initial HTTP tests missed: lost leading
rich-text content, stale history after reconnect, search-action updates, editor
focus, dark icon contrast, and a literal `&nbsp;` after mentions. Fixes were made
in application code and covered by focused checks. No V library was patched.

The transient connection errors recorded while deliberately restarting the dev
server are expected. Browser-provider Web Push still needs an HTTPS origin and
an end-to-end provider test. The screenshots are local evidence, not a claim of
visual identity with the reference app.
