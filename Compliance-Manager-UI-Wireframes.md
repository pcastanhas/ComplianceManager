# Compliance Manager — UI Wireframes (Draft v0.1)

**Status:** Draft — companion to the data model spec.
**Design language:** card-based, deadline-first, not row-tables. Flat, clean surfaces. Status and urgency encoded by color so the screen is scannable without reading. Both violations and Local Law filings share every screen.

---

## Design Language & Component Inventory

**Principles**
- Lead with "what's at risk and by when," not a grid to scan.
- Each obligation card encodes three signals without reading text: a status dot (urgency), a deadline chip (time), and a status pill (lifecycle stage).
- Primary action adapts to lifecycle state: `Certify`, `Start filing`, `Upload docs`, `Open`.
- Color is semantic: danger = overdue/penalty, warning = due soon/blocked, info = in progress, success = accepted/in-sync, neutral = upcoming.

**Reusable components**
| Component | Description |
|---|---|
| Obligation card | Building + condition, type badge, deadline chip, status pill, assignee, primary action |
| Metric tile | Label + large number; colored number for urgent counts |
| Status pill | Lifecycle state (`In progress`, `Due`, `Penalty enforcement`, …) |
| Deadline chip | Countdown with urgency color (`Overdue 2d`, `Due in 6d`, `Certify in 4d`) |
| Type badge | `HPD · Class C` (violation) or `DOB · Local Law` (filing) with distinct icons |
| Proof checklist row | Doc name + present/missing icon + View/Upload |
| Cost line | Step + job/GL/cost codes + est/actual + posting indicator |
| Party row | Avatar + name/company + role pill |
| Timeline node | Dot (done/current/next) + event + actor + timestamp |
| Reconciliation panel | "Our record" vs "Agency/ERP record" + in-sync indicator |

---

## Screen 1 — Dashboard / Work Queue (sketched)

**Purpose:** triage. What needs attention across the portfolio, ranked by deadline, violations and filings combined.

```
┌────────────────────────────────────────────────────────────┐
│ [shield] Portfolio compliance              [ search……… ]    │
│          64 buildings · 4 agencies                          │
├────────────────────────────────────────────────────────────┤
│ Overview | Violations | Local Law | Buildings | Documents   │
├────────────────────────────────────────────────────────────┤
│ ┌─Overdue─┐ ┌─Due wk─┐ ┌─Upcoming─┐ ┌─Reg alerts─┐          │
│ │   3     │ │   7    │ │   14     │ │     2       │  (tiles)  │
│ └─────────┘ └────────┘ └──────────┘ └─────────────┘          │
│                                                              │
│ Needs attention            sorted by deadline · all types   │
│                                                              │
│ ● OVERDUE                                                    │
│ ┌──────────────────────────────────────────────────────┐   │
│ │ ● No heat / hot water            [Overdue 2d]         │   │
│ │   1247 Grand Concourse, Bronx                         │   │
│ │   [HPD·Class C] [Penalty enforcement] $250/day        │   │
│ │   (JM) Joe M. · super                       [Open ↗]  │   │
│ └──────────────────────────────────────────────────────┘   │
│ ┌──────────────────────────────────────────────────────┐   │
│ │ ● LL152 gas piping inspection    [Overdue 5d]         │   │
│ │   512 West 134th St · [DOB·Local Law] up to $10,000   │   │
│ │   (PV) Precision Plumbing · vendor          [Open ↗]  │   │
│ └──────────────────────────────────────────────────────┘   │
│ ● DUE THIS WEEK                                              │
│ ┌─ LL84 energy benchmarking ····· [Due in 6d] ────────┐    │
│ │  88 Saint Marks Pl · Portfolio Manager · due May 1   │    │
│ │  (EC) Energo · consultant            [Start filing ↗]│    │
│ └──────────────────────────────────────────────────────┘   │
│ ┌─ Vermin infestation ··········· [Certify in 3d] ────┐    │
│ │  1010 Ocean Ave · [HPD·Class B] [In progress]        │    │
│ │  (RA) Rosa A. · super                    [Certify ↗] │    │
│ └──────────────────────────────────────────────────────┘   │
│           + 12 more due this month                          │
└────────────────────────────────────────────────────────────┘
```

**States:** card urgency colors shift by deadline; primary action label switches by lifecycle state; tiles recolor when counts cross thresholds.

---

## Screen 2 — Obligation Detail (sketched)

**Purpose:** the full record for one obligation — state, what's blocking it, the team, costs, evidence, history, and whether the data can be trusted.

```
┌────────────────────────────────────────────────────────────┐
│ ← Overview / 240 East 52nd St                                │
│                                                              │
│ Lead paint hazard  [Order 616]      [Correcting·blocked]     │
│ 240 East 52nd St · Apt 4R · #14872330  [Certify by Apr26·4d] │
│                                                              │
│ [Upload missing docs ↗] [🔒 Certify] [Contest (testing) ↗]  │
│ ⚠ Certification blocked — 2 required docs missing. No eCert. │
│                                                              │
│ (ME) Maria Ellis — Internal lead · accountable [Reassign]    │
│                                                              │
│ ┌ Key facts ─────────────────────────────────────────────┐  │
│ │ HPD·Class C | Lead | Issued Mar18 | Correct Apr8·done   │  │
│ │ Certify by Apr26 | eCertification: Not eligible          │  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Required proof of correction ──────────────────────────┐   │
│ │ ✓ EPA firm certification                       [View]  │   │
│ │ ✓ Remediation invoice                          [View]  │   │
│ │ ⚠ Dust-wipe clearance results                  [Upload]│   │
│ │ ⚠ Technician training certificate              [Upload]│   │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Team ──────────────────────────────────  [+ Add party] ┐  │
│ │ (LX) LeadX Abatement — Daniel Okafor   Contractor·prim  │  │
│ │ (SK) Sarah Kim, PE — Kim Environmental Engineer·assessor│  │
│ │ (MC) Marin & Cole LLP — 616 contest    Attorney        │  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Remediation costs ──────────────────  [↻ Sync to ERP] ─┐  │
│ │ Entity · 240 E 52nd LLC               budget   actual   │  │
│ │ ✓ Lead risk assessment [02-8213][GL6420] 1,200  1,150 ✓ │  │
│ │ ✓ Abatement apt 4R     [02-8313][GL6420] 6,500  7,200 ✓ │  │
│ │ ⏱ Dust-wipe clearance  [02-8216][GL6420]   800    —   ⏱ │  │
│ │ Total            [+$650 vs budget]       8,500  8,350   │  │
│ │ ✓ ERP posted $8,350 · in sync with Yardi · synced 1h    │  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Files & photos · supporting, not proof ────────────────┐  │
│ │ [img] [img] [letter.pdf] [+ Add]                        │  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Activity ──────────────────────────────────────────────┐  │
│ │ ✓ Violation issued — HPD inspector — Mar 18             │  │
│ │ ✓ Imported from Open Data — system — Mar 19             │  │
│ │ ✓ Vendor assigned — Mar 24                              │  │
│ │ ✓ Remediation completed · EPA cert — Apr 9              │  │
│ │ ⏱ Dust-wipe scheduled — Apr 22 (in progress)            │  │
│ │ ○ Certify correction — due Apr 26 (next)                │  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Notes ─────────────────────────────────────────────────┐  │
│ │ (DO) Tenant 4R weekend access only — Apr 7              │  │
│ │ (ME) Holding cert until lab results — Apr 22            │  │
│ │ [ Add a note………………… ] [Post]                            │  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ ┌ Reconciliation                         [✓ In sync] ────┐  │
│ │ Our record: Correcting (since Apr 9)                    │  │
│ │ HPD record: Open (synced 2h ago)                        │  │
│ │ ℹ 70-day auto-close N/A — lead requires HPD verification│  │
│ └──────────────────────────────────────────────────────── ┘  │
│                                                              │
│ [Watching ▾ + watcher avatars]                               │
└────────────────────────────────────────────────────────────┘
```

**Notable behaviors**
- Certify is locked until the proof checklist is complete; the banner states why.
- `actual` cost is read-only (synced from ERP); over-budget lines flag amber.
- Internal lead is visually distinct from external team and auto-watches.
- Reconciliation shows belief vs. record; a divergence (we filed / agency still open past lag, or a reopen) lights up here.
- In production these panels become tabs (Overview / Team / Costs / Files / Notes); the wireframe stacks them.

---

## Screen 3 — Building View (planned, not yet sketched)

**Purpose:** everything for one address.
- Header: building identity, owning entity, HPD registration status + expiry (alert if expiring).
- Open obligations (same card style, filtered to this building).
- Recurring Local Law calendar: a timeline/calendar of upcoming filing windows (FISP cycle, LL84/LL97 annual, LL152 cohort, boiler/elevator) generated by the obligation generator.
- Equipment list (drives equipment-based obligations).
- Cost rollup for the building (year-to-date remediation spend, synced from ERP).

## Screen 4 — Board by State (planned alternative)

**Purpose:** manage by workflow stage instead of by deadline.
- Kanban columns = normalized lifecycle states: Upcoming → Due → In progress → Filed/pending → Closed, with an At-risk/Overdue swimlane.
- Cards drag between columns; column counts shown.
- Same obligation cards as the dashboard.

---

## Open UI Questions
1. Should the proof checklist collapse once complete, or stay visible?
2. Reconciliation inline on each detail vs. a portfolio-wide "exceptions" view that surfaces only divergences?
3. Dashboard default grouping — by deadline (current) or a toggle to group by building / by agency?
