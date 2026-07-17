# Governance

The Tin is a small, community-funded hobby project. This document describes
honestly how it is run today, and what happens if that changes.

## How decisions are made

The Tin currently follows a single-maintainer model: the maintainer
([@tomasreyes](https://github.com/tomasreyes)) has final say on code, releases,
and spending. In practice:

- **Features and changes** are discussed in GitHub issues before large work
  starts (see [CONTRIBUTING.md](CONTRIBUTING.md)). Anyone can propose anything;
  the maintainer decides what lands.
- **All changes land through pull requests** on the public repository — there
  is no private development branch.
- **Money does not buy influence.** Donations fund running costs (price API,
  Apple developer fee, server hosting) via a public ledger. Donating does not
  grant any say over the roadmap, and contributing code does not create any
  claim on funds.

## Becoming a maintainer

Contributors who show sustained, quality involvement (reviews, fixes, card
data stewardship) may be invited to become co-maintainers with commit access.
There is no formal quota or timeline — it happens when trust is established.

## Funds

Project funds are held and disbursed transparently through the project's
fiscal host, with a public ledger of income and expenses. Funds go first to
direct project costs (API subscriptions, developer program fees, hosting, and
similar). If donations exceed running costs, maintainers may be compensated
for their time from the surplus — like every other expense, any such payout
appears on the public ledger. There are no salaries or guarantees; costs are
always covered first.

## Succession

Everything needed to run The Tin is in this repository under AGPL-3.0: the
app, the catalog pipeline, the scanner pipeline, and a self-hostable catalog
server. If the maintainer becomes unresponsive for an extended period
(90+ days with no activity and no notice):

1. Co-maintainers, if any exist at that time, assume full control.
2. Otherwise, the community is free — and encouraged — to fork under the terms
   of the license (rebranded per [TRADEMARK.md](TRADEMARK.md)).
3. Remaining funds are handled according to the fiscal host's dissolution
   policy.

## Changes to this document

Changes to governance are proposed as pull requests against this file, so the
history of how the project is run is itself public.
