# Proposal: optional WHOOP API source (for review — no code written)

Status: **decided — no API integrations. NOOP stays local and keeps ZIP/CSV import only.** The terms review below is kept as the reason.

Original status: draft. Facts below come from WHOOP's and Polar's developer pages, read on 2026-10-15. Items marked *unverified* were not found in the docs.

## In one paragraph

NOOP could let you, if you choose, pull your own official WHOOP scores (recovery, strain, sleep, workouts) straight from WHOOP instead of importing a ZIP. It would be off by default, and the data would be stored only on your device. The main obstacle is not privacy but WHOOP's rules for apps, described below.

## What I verified (WHOOP)

| Question | Finding |
|---|---|
| Sign-in method | OAuth 2.0 authorization code. Auth: `api.prod.whoop.com/oauth/oauth2/auth`, token: `.../oauth2/token`. |
| PKCE / native apps | **Not documented.** The docs show a client secret in the flow and say to keep it server-side. *Unverified* whether a secret-less native flow works. |
| Scopes | `read:recovery`, `read:cycles`, `read:sleep`, `read:workout`, `read:profile`, `read:body_measurement`, plus `offline` for a refresh token. |
| Data | `/v2/cycle`, `/v2/recovery`, `/v2/activity/sleep`, `/v2/activity/workout`, `/v2/user/profile/basic`, `/v2/user/measurement/body`. |
| Paging | `limit` max 25, `start`/`end`, `nextToken`; newest first. |
| Limits | 100 requests/min, 10,000/day per app. HTTP 429 when exceeded; headers `X-RateLimit-*`. |
| Disconnect | `DELETE /v2/user/access` revokes access. |
| Refresh tokens | Each refresh invalidates the old pair; the newest must be saved, and refreshes must not run concurrently. |
| Redirect | Must be registered in WHOOP's dashboard; custom-scheme redirects are shown as examples. |
| Registration | Developer dashboard, team required, up to 5 apps per account. |
| **Member cap** | New apps are in **Sandbox: max 10 WHOOP members**. Each higher tier (100, 1,000, 5,000, unlimited) needs manual approval, a privacy-policy URL, adherence to WHOOP's API Terms and brand rules, and **at least 50% of the current tier's cap already connected**. |
| WHOOP 5 / MG | The API pages do not mention them. *Unverified* whether their data appears. |

I did **not** read WHOOP's API Terms of Use, so I can't say what they allow for an open-source app or for local storage.

## The blocker, and the option that fits NOOP

- A shared "NOOP" WHOOP app would need a client secret that cannot ship inside a public app, so it would need a NOOP-run server (which conflicts with "no servers") and would hit the 10-member sandbox cap until approved.
- **Option A — bring your own app (recommended if you want this at all).** You create a free WHOOP developer app (the 10-member sandbox is enough for yourself), paste your own client ID and secret into NOOP, and NOOP signs in directly. The secret lives in your Keychain / Android Keystore. No NOOP server, no shared secret, no cap problem. Cost: about 10 minutes of setup, which is not a casual feature. Whether WHOOP allows a localhost/custom-scheme redirect for this is *unverified*.
- **Option B — NOOP-run token service.** Not recommended: it adds a server and a company-held secret, and needs WHOOP approval.
- **Option C — stay with ZIP import.** No change; the export already holds most of the same data.

## What would leave your device (Option A)

- Requests from your device **directly to WHOOP** only: the sign-in, then reads of the scopes you ticked. Nothing goes to any NOOP server, analytics or third party.
- Fetched data is stored locally, labelled "WHOOP score", and is never merged over your raw strap data.
- Fetching runs only when you press **Sync** (no background sync at first).
- **Disconnect** revokes access at WHOOP and deletes the tokens. A separate button deletes the data fetched through the API.

## Simple screen design

One card under Import & Export, **"Connect WHOOP (optional)"**:
1. Short explainer: what is sent, where it is stored.
2. Fields for your client ID and secret, and a link to the setup steps.
3. **Connect** → WHOOP's own consent page → back in NOOP.
4. States: *Not connected* / *Connected · last synced* with **Sync now** and **Disconnect & delete**.

## Polar (if "Flow" means Polar Flow — please confirm)

- Also OAuth 2.0 with a client secret (Basic auth at the token endpoint); PKCE not mentioned. Register at admin.polaraccesslink.com. The same bring-your-own-client approach would apply.
- Each user must also be registered through a users endpoint, and must accept consents on Polar's side or data calls return 403.
- Access tokens do not expire unless revoked. Rate limits scale with the number of users.
- Windows: exercises only from the last 30 days uploaded to Flow, daily activity up to 365 days back. A one-time history backfill is therefore limited.
- Governed by the Polar AccessLink Limited License Agreement, which I have **not** read.

## Decisions I need from you

1. Option A, C, or something else?
2. Does "Flow" mean Polar Flow?
3. OK for me to read the WHOOP API Terms and Polar license next, and report back before any code?

Nothing in this proposal implies endorsement by WHOOP or Polar.

## Terms review (2026-10-15, from the official pages; not legal advice)

**WHOOP API Terms of Use** — would conflict with NOOP's design in several places:
- Developer credentials "may not be embedded in open-source projects" (NOOP is open source).
- No building databases or permanent copies of WHOOP data; cached data must follow cache headers; data must be encrypted at rest. NOOP's whole model is a permanent local database.
- No using API data to create, train, test or improve any ML/AI model. This would rule out calibrating NOOP's estimates against API-fetched scores.
- Not for medical-device or medical-advice features; no implying partnership or endorsement; WHOOP can end access at any time.

**Polar AccessLink License Agreement:**
- Licence is framed for proprietary app development; software parts may be distributed only in binary form and may not be reverse-engineered, which sits awkwardly with open source.
- Requires a privacy policy, Polar credit wherever data is shown, and deletion of tokens and data on request or termination. Polar can terminate at any time; Finnish law, arbitration in Oulu.

**Conclusion:** the API route is a poor fit for an open-source, local-first app. The WHOOP data export you download yourself is not an API integration and is unaffected by these terms.

## Polar without the API
If Polar data is wanted later, the compliant local route is Polar Flow's own data export file (user-downloaded), imported like the WHOOP ZIP. Format not yet inspected.
