# GCP Marketplace Pub/Sub Integration and Customer Identity Resolution

**Date**: 2026-11-11
**Status**: Complete — one open dependency (CIAM identity federation, Path A vs B decision)
**Authors**: Cristiano Veiga
**Related**: [GCP-1377](https://redhat.atlassian.net/browse/GCP-1377) (spike), [PR #168](https://github.com/openshift-online/gcp-hcp/pull/168) (EGW service identity), [egw-service-identity](../../design-decisions/identity/egw-service-identity.md) (design decision)

## Problem Statement

The GCP-HCP Marketplace integration needs to bind the subscribing customer as `service-admin` in their namespace. The Cedar authorization model ([gcp-cedar-public-api-authorization](../../implementation-plans/gcp-cedar-public-api-authorization.md)) defines `RoleBinding.Spec.Subject` as a **user email**, with principals sourced from **Google ID tokens** validated by the ESPv2 sidecar. The Marketplace controller (per [gcp-cross-region-resource-replication](../../implementation-plans/gcp-cross-region-resource-replication.md)) creates this initial binding through the leader.

This study answers: **where does the subscribing customer's Google email come from?** It examines how the Partner Integration team consumes GCP Marketplace Pub/Sub events, what identity data is available at each layer, and the path to obtaining the email.

## How Partner Integration Consumes GCP Marketplace Pub/Sub

Google Cloud Marketplace publishes entitlement lifecycle events to a Pub/Sub topic in the `redhat-marketplace-public` GCP project (plus a stage project). Two **push subscriptions** fan out from the same topic:

| Subscription | Target | Purpose |
|---|---|---|
| `rh-it-partner` | Entitlement Gateway, `POST /v1/gcp/from-subscription` | Entitlement lifecycle (system of record) |
| `rh-cloudoscope-private-offer-acceptance` | Cloudoscope, `POST /v1/private-offer/acceptance/gcp` | Private offer acceptance analytics → Mongo → Snowflake |

The fan-out is deliberate (ADR `adr-20260717-gcp-private-offer-acceptance-cloudoscope`): analytics ingest retries must not risk the gateway's ACK/approval workflows.

### Entitlement Gateway

Repo: [`it-partner-integration/ibm-entitlement-gateway`](https://gitlab.cee.redhat.com/it-partner-integration/ibm-entitlement-gateway) (Java/Spring, package `com.redhat.api.entitlementgateway`, deployed at `ibm-entitlement-gateway.api.redhat.com`). The Pub/Sub integration lives in `server/src/main/java/com/redhat/api/entitlementgateway/infrastructure/http/gcp/`:

- **`PubSubPushMessage`** — the wrapped push envelope: base64-encoded `message.data`, `messageId`, `publishTime`, `subscription`
- **`JacksonPubSubPushMessageExtractor`** — base64-decodes `message.data` and binds it via Jackson
- **`GcpMarketplaceEvent`** — polymorphic event model discriminated by `eventType` (`ENTITLEMENT_CREATION_REQUESTED`, `ENTITLEMENT_OFFER_ACCEPTED`, `ENTITLEMENT_ACTIVE`, `ENTITLEMENT_PLAN_CHANGE_REQUESTED/CHANGED`, `ENTITLEMENT_PENDING_CANCELLATION/CANCELLED/DELETED`, account events)
- **`GcpMarketplaceApiV1Impl.receiveMarketplacePubSubEvent`** — `@PostMapping("from-subscription")`; a switch over event types drives `GcpMarketplaceService` (create/approve SaaS subscriptions, plan changes, cancellations). ACKs by returning 200 `"ack"`; any other status nacks and Pub/Sub redelivers (DLQ is the subscription's responsibility)

After receiving events, the gateway enriches them by calling the **Partner Procurement API** `entitlements.get` (`GcpServicePortal`/`RemoteGcpServicePortal`) — the Pub/Sub payload alone is not a complete entitlement record.

Note: the push endpoint is **public/unauthenticated** (`@Hidden` in OpenAPI, "public endpoint as required by pubsub") — that is Google's push model; authenticity relies on Pub/Sub delivery, not caller auth.

### Cloudoscope

Repo: [`it-partner-integration/cloudoscope/cloudoscope`](https://gitlab.cee.redhat.com/it-partner-integration/cloudoscope/cloudoscope). Mirrors the gateway's pattern (`PubSubPushMessage`, `JacksonPubSubPushMessageExtractor`, `PrivateOfferAcceptanceApiV1Impl`, `GcpPrivateOfferAcceptanceService`, `RemoteGcpPartnerProcurementPortal`), persists private-offer acceptances to Mongo (`gcpPrivateOfferAcceptance`) keyed by the Pub/Sub `eventId`, for Snowflake joins to the private offer tracker on `offerId` (= `quoteExternalName`).

### Key documentation

- [`docs/research/gcp-po-acceptance-implementation-notes.md`](https://gitlab.cee.redhat.com/it-partner-integration/partner-integration-docs/-/blob/main/docs/research/gcp-po-acceptance-implementation-notes.md) — topic, subscriptions, event handling rules, Procurement field mapping
- [`docs/architecture/adr-20260717-gcp-private-offer-acceptance-cloudoscope.md`](https://gitlab.cee.redhat.com/it-partner-integration/partner-integration-docs/-/blob/main/docs/architecture/adr-20260717-gcp-private-offer-acceptance-cloudoscope.md) — decision record with component diagram
- [`docs/reference/cloudoscope-gcp-datafeeds.md`](https://gitlab.cee.redhat.com/it-partner-integration/partner-integration-docs/-/blob/main/docs/reference/cloudoscope-gcp-datafeeds.md) — the other GCP data path (GCS report buckets, not Pub/Sub)

## Finding 1: The Customer Email Is Not in the Event Pipeline

The subscribing user's Google email is **not captured, cannot be captured by changing the EGW code, and is not in reach of the event pipeline**. Google's Cloud Commerce deliberately anonymizes the customer:

| Source | Fields available | Email |
|---|---|---|
| Pub/Sub event payload | `eventId`, `providerId` (Red Hat's provider ID), `eventType`, `entitlement.id`, `account.id` | No |
| Procurement API `Entitlement` | id, provider, plan, state, `productExternalName`, `offerEndTime`/`offerDuration`, `account`, `quoteExternalName` | No |
| Procurement API `Account` | `name`, `createTime`, `updateTime`, `provider`, `state`, `approvals[]`, `resellerParentBillingAccount` — the only user-data field (`inputProperties`) is **deprecated** | No |
| Persisted EGW domain (`GcpAccount`, `SaasEntitlementDetails`) | `rhAccountId`, `gcpAccountId` (opaque), `billingAccountId` | No |

### Partial identity bridges that exist today

1. **Red Hat principal (customer-initiated, opt-in).** When a customer connects their GCP account to a Red Hat account via the Partner Link Portal, the BFF calls `POST /v1/gcp/orders/link-account` with `gcpProcurementAccount`, `accountId` (RH), and `userLogin` (RH login — an email). Persisted on `GcpAccount`. This is the **Red Hat** user, not the Google user, and only exists if linking completed.
2. **Billing admin email domain (delayed, coarse).** Cloudoscope's Customer Insights reports (GCS buckets, ~2-day delay) carry `domain()` — the email **domain** of the organization's billing administrator (excluded for personal accounts) — plus `company()`, `country`, `externalAccountId`, `accountId`. Full email is never present.

## Finding 2: The Documented Path to the Email — Google's Frontend Sign-Up Flow

Per Google's [frontend integration docs](https://docs.cloud.google.com/marketplace/docs/partners/integrated-saas/frontend-integration), when a customer clicks **"Register with Red Hat"** on Cloud Marketplace, Google POSTs to the configured **Sign up URL** with an `x-gcp-marketplace-token` JWT (RS256-signed by `cloud-commerce-partner@system.gserviceaccount.com`, 5-minute expiry):

```json
{
  "iss": "https://www.googleapis.com/robot/v1/metadata/x509/cloud-commerce-partner@system.gserviceaccount.com",
  "exp": "CURRENT_TIME + 5 minutes",
  "aud": "PARTNER_DOMAIN_NAME",
  "sub": "PROCUREMENT_ACCOUNT_ID",
  "google": {
    "roles": ["account_admin" | "project_editor"],
    "user_identity": "OBFUSCATED_USER_ID",
    "orders": ["ENTITLEMENT_ID1", "..."]
  }
}
```

The JWT contains no email, but the documented flow yields one:

1. Verify the JWT (signature against Google's public key at the `iss` URL, `aud` = our domain, `exp`, non-empty `sub`)
2. Use `google.user_identity` as **`login_hint`** in a Google OAuth 2.0 consent flow — pre-selects the same Google account used in Marketplace
3. Call the **Google UserInfo API** with the OAuth token → **verified email**
4. Confirm the returned user ID matches `user_identity`

The JWT's `sub` (procurement account ID) and `orders` (entitlement IDs) map onto what EGW already persists (`gcpAccountId`, entitlement IDs), so the caller's entitlement can be confirmed via the EGW read APIs — the access that [PR #168](https://github.com/openshift-online/gcp-hcp/pull/168)'s service identity design provides.

Caveats (from Google's documentation):

- One user can have multiple procurement account IDs; multiple users can share one procurement account ID — so bind per **user** (email), not per procurement account
- `google.roles` distinguishes `account_admin` (Billing Account Administrator / Order Administrator) from `project_editor` (Entitlement Manager) — a natural eligibility gate for the initial `service-admin` grant
- The JWT expires in 5 minutes; the **Login URL** (with SSO enabled) receives the same JWT format on each login — a recurring touchpoint for binding additional users

## Finding 3: Current Blocker — RH SSO Enforced Login, No Google Federation

Per Partner Integration (Vidhya Chidambaram, Slack, 2026-11):

- The `x-gcp-marketplace-token` JWT **is received** today ("we do get customer's jwt")
- But the listing is configured so the sign-up button redirects to **Red Hat SSO with enforced Red Hat login** — the `login_hint` flow is never attempted ("the way listing is configured today, wouldn't even attempt to get the customer's IAM credential")
- Resolving the Google identity requires **identity federation in RH SSO** — owned by CIAM — plus RH's Google cloud administrators (the OAuth client for the consent flow is RH-owned)

The captured principal at sign-up is therefore the **Red Hat login** (the existing `createAndLinkAccount`/`userLogin` flow). "Not supported" reflects the current state, not a Google-side limit — Google's documented flow supports the `login_hint` path; it is the RH SSO enforcement layer that must allow it.

CIAM convention (per the [egw-service-identity](../../design-decisions/identity/egw-service-identity.md) design decision, D2): all clients — including non-production-purpose ones — are created in the **production SSO**, isolated as separate clients. There is no separate non-prod SSO for external integrations; consequence: non-production environments couple to production SSO availability.

## Design Tension and Paths Forward

The Cedar plan assumes principals = **Google emails** (Google ID tokens via ESPv2), but the marketplace funnel captures only the **Red Hat login**. These identity systems currently cannot be joined — there is no Google email anywhere in the funnel and no RH↔Google identity mapping.

| Path | What it takes | Consequence |
|---|---|---|
| **A — CIAM identity federation** (get the Google email) | Google as federated IdP on a dedicated (non-production-purpose, isolated) client in the production SSO; `login_hint` passthrough into the Google consent flow; verified Google email + `user_identity`/Google `sub` in the resulting token claims; RH Google cloud administrators engaged for the OAuth client | Google-email principals work as designed; verify the token/claim shape the public API validates (raw Google ID token via ESPv2 vs federated RH SSO token) matches the RoleBinding subject normalization |
| **B — RH identity as principal** | No new external dependencies | The Cedar/ESPv2 principal model must be redesigned; otherwise marketplace and API identities are split-brain and cannot be correlated |

### Recommended sequencing

1. **Track the CIAM conversation as a dependency** of the Marketplace design decision — it decides Path A vs B (in flight: Shreyans Mulkutkar engaging RHSSO/CIAM)
2. **Build the identity-independent parts meanwhile**: the sign-up endpoint (JWT verification, `sub`/`orders` correlation via EGW reads) and the Marketplace controller's RoleBinding creation — only the *source of the subject* depends on the identity outcome
3. **Use EGW's existing `gcpAccountId ↔ rhAccountId` linkage** as the entitlement correlation mechanism either way — it is proven and in production

## Where Changes Land

| Component | Change | Repo |
|---|---|---|
| Sign-up endpoint (new) | JWT verification, OAuth `login_hint` flow, UserInfo call, entitlement correlation | gcp-hcp / gecko — new landing endpoint, registered as Sign up URL in Producer Portal |
| Marketplace controller | Create the initial `service-admin` RoleBinding from the verified subject | gcp-hcp (gecko) |
| EGW reads | Entitlement lookup by procurement account ID / entitlement ID | gcp-hcp (gecko) — in flight via PR #168 |
| Producer Portal config | Sign up URL, Login URL, optionally SSO | GCP-side, coordinated with Partner Integration |
| RH SSO (CIAM) | Google federation + `login_hint` passthrough (Path A only) | CIAM / RHSSO team |
| Entitlement Gateway | **No changes** — the email is not obtainable there | it-partner-integration (unchanged) |

## References

- [GCP-1377](https://redhat.atlassian.net/browse/GCP-1377) — spike: Entitlement Gateway service identity and credential lifecycle
- [PR #168](https://github.com/openshift-online/gcp-hcp/pull/168) — EGW service identity design decision
- [PR #169](https://github.com/openshift-online/gcp-hcp/pull/169) — POC: Keycloak verification of Google-managed signJwt assertions
- [Google: Integrate your app's frontend (Cloud Marketplace)](https://docs.cloud.google.com/marketplace/docs/partners/integrated-saas/frontend-integration) — sign-up JWT, `login_hint`, UserInfo flow
- [Google: Procurement API `providers.accounts`](https://docs.cloud.google.com/marketplace/docs/partners/commerce-procurement-api/reference/rest/v1/providers.accounts) — Account resource (no email; `inputProperties` deprecated)
- [Google: Backend integration](https://docs.cloud.google.com/marketplace/docs/partners/integrated-saas/backend-integration) — Pub/Sub event types, service account linking
- EGW repos: [`it-partner-integration/ibm-entitlement-gateway`](https://gitlab.cee.redhat.com/it-partner-integration/ibm-entitlement-gateway), [`it-partner-integration/cloudoscope/cloudoscope`](https://gitlab.cee.redhat.com/it-partner-integration/cloudoscope/cloudoscope), [`it-partner-integration/partner-integration-docs`](https://gitlab.cee.redhat.com/it-partner-integration/partner-integration-docs)
