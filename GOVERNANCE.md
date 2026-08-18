# Governance

The Tin is a small, community-funded hobby project. This document describes
honestly how it is run today, and what happens if that changes.

## How decisions are made

The Tin currently follows a single-maintainer model: the maintainer
([@treyes133](https://github.com/treyes133)) has final say on code, releases,
and spending. In practice:

- **Features and changes** are discussed in GitHub issues before large work
  starts (see [CONTRIBUTING.md](CONTRIBUTING.md)). Anyone can propose anything;
  the maintainer decides what lands.
- **All changes land through pull requests** on the public repository — there
  is no private development branch.
- **Money does not buy influence.** Sponsorships fund running costs (price API,
  Apple developer fee, server hosting). Sponsoring does not grant any say over
  the roadmap, and contributing code does not create any claim on funds.

## Becoming a maintainer

Contributors who show sustained, quality involvement (reviews, fixes, card
data stewardship) may be invited to become co-maintainers with commit access.
There is no formal quota or timeline — it happens when trust is established.

## Funds

Funding runs through [GitHub Sponsors](https://github.com/sponsors/treyes133),
as a personal listing rather than an organisation one — GitHub will not pay an
organisation out to an individual Stripe account, so the org listing could
never publish. There is no fiscal host: Open Source Collective declined the
project on 2026-07-25, and no other host has been applied to.

That has a consequence worth stating plainly, because an earlier version of
this document promised otherwise: **there is no public ledger of income and
expenses, and GitHub Sponsors provides no mechanism for one.** What is public
is the sponsor list ([SPONSORS.md](SPONSORS.md), maintained by hand), the
monthly goal and progress toward it (on the Sponsors page and in the app under
Settings → Support), and the cost breakdown in SPONSORS.md.

Funds go first to direct project costs (API subscriptions, developer program
fees, hosting, and similar). If sponsorship exceeds running costs, the
maintainer may be compensated for time from the surplus. There are no salaries
or guarantees; costs are always covered first.

## Succession

Everything needed to run The Tin is in this repository under AGPL-3.0: the
app, the catalog pipeline, the scanner pipeline, and a self-hostable catalog
server. If the maintainer becomes unresponsive for an extended period
(90+ days with no activity and no notice):

1. Co-maintainers, if any exist at that time, assume full control.
2. Otherwise, the community is free — and encouraged — to fork under the terms
   of the license (rebranded per [TRADEMARK.md](TRADEMARK.md)).
3. Sponsorships are cancelled, so nothing keeps accruing to a project that
   has stopped. Anything already received sits in a personal account with no
   host to disburse it; there is no mechanism to redistribute it, which is one
   more reason to keep the balance near zero.

## Changes to this document

Changes to governance are proposed as pull requests against this file, so the
history of how the project is run is itself public.
