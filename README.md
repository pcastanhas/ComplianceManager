# NYC Compliance Manager — Project README

**What this is:** design notes for an in-house system to track NYC building violations and Local Law filing obligations from issuance/generation through "filed and accepted," across a portfolio.

**Use this file to resume:** it captures the decisions made so far, the architecture, what's been produced, open questions, and the next steps. Start here, then open the linked docs.

---

## 1. Goal

One system that monitors compliance obligations across a building portfolio and tracks each one through its full lifecycle to closure — covering both **reactive** agency violations and **proactive** recurring Local Law filings, with deadlines, remediation work, document evidence, costs, and an audit trail.

## 2. Confirmed scope & constraints

- **Agencies in scope:** HPD (housing maintenance) + the DEP / DSNY / DOHMH cluster (OATH-adjudicated). DOB and FDNY are **out of scope** for now.
- **Build approach:** build in-house from scratch.
- **Portfolio size:** ~25–100 buildings.
- **Phasing:** HPD first (clean data, BBL/BIN matching, biggest volume), then the OATH cluster as a bounded phase 2. Build the seams now; defer the second connector.

## 3. Key architectural decisions

1. **Two paradigms, not five agencies.** HPD = correct-then-certify (with a possible 70-day re-inspection audit). DEP/DSNY/DOHMH = OATH summonses (hearing/cure/penalty). The state machine has both branches.
2. **Unified obligation engine.** One core handles reactive violations and proactive Local Law filings; they share the deadline engine, state machine, filings, documents, reconciliation, and audit. The only structural difference is the *trigger*.
3. **Rules-driven obligation generator** (the one net-new component for Local Law). It materializes recurring obligations from declarative `obligation_rule` rows + building attributes. Variation lives in ~4 `recurrence_strategy` values (fixed_calendar, cohort_cycle, equipment_driven, event_triggered) — not in per-law code. Heavy-computation laws (LL97 emissions) get an upstream module that *emits* a standard obligation.
4. **Deterministic core; AI at the edges.** Deadlines, applicability, penalties, and "filed/accepted" are rules/feed-driven — never AI. AI is a later, optional assistant for: extracting structure from free-text violation detail, drafting comms, and prioritization rationale. It always *proposes* into a review gate (`field_provenance`), never writes truth. One ML-ish exception worth early consideration: fuzzy matching of OATH summonses to buildings.
5. **Single source of truth per concern.** The **ERP** (Yardi/MRI/GL) owns cost classification + job-cost progression; the **agency feed** owns compliance status/closure. The tracker holds operational state plus keys to reconcile against both, and does not duplicate either.
6. **Belief vs. record reconciliation.** Internal state is diffed against the agency feed (and ERP posted actuals) every cycle; divergences (lag, audits, reopens, out-of-sync costs) are the valuable signal.

## 4. Lean architecture (right-sized for 25–100 buildings)

- Scheduled daily ingestion → relational store (Postgres) → deadline/status engine → web app → object storage for documents → notification/alert service. No streaming, microservices, or queues.
- **Two ingestion connectors** behind one generic connector interface:
  - HPD violations — NYC Open Data `wvxf-dwi5` (Socrata SODA, daily).
  - OATH summonses (DEP/DSNY/DOHMH) — NYC Open Data `jz4z-kudi` (OATH Hearings Division Case Status).
- **Obligation generator** for Local Law (proactive).
- **Reconciliation loop** (belief vs. agency record; belief vs. ERP actual).
- **ERP sync** for cost data (job_code/GL/cost_code → ERP job; read actuals back).

**Suggested build order:** property-identity table → HPD connector + normalized status → deadline engine + alerts (working monitor on its own) → document capture + filings → obligation generator + Local Law rules → OATH connector → reconciliation/audit reporting → ERP cost sync → AI assists.

## 5. Data model — current state (v0.2)

See `Compliance-Tracker-Data-Model.md`. Core entities:
- `entity` → `building` (entity lives on building) → `equipment`, `obligation`.
- `obligation` (unified; `obligation_type` + `paradigm`; `internal_lead_id`; computed deadline fields; `parent_obligation_id` for missed-filing→violation and inspection→repair loops).
- `obligation_rule` (drives the generator).
- `obligation_party` (multi-vendor: contractor / engineer / attorney / expediter / super / owner_rep). Internal lead is a separate singular field on the obligation.
- `remediation_task` (operational cost only: `estimated_cost`, `job_code`, `gl_account`, optional `cost_code`, read-only synced `actual_cost`; ERP owns capital/expense + progression).
- `filing`, `document` (split `required_proof` / `supporting`), `proof_requirement`, `note`, `subscription`.
- Integrity: `agency_record_snapshot`, `event_log` (append-only), `field_provenance` (AI seam), `alert`.

## 6. UI — current state

See `Compliance-Tracker-UI-Wireframes.md`. Design language: card-based, deadline-first, not row-tables; status/urgency encoded by color.
- **Sketched:** dashboard/work queue (card feed), obligation detail (status, blocking proof checklist, internal lead, team, ERP costs, files, timeline, notes, reconciliation).
- **Planned:** building view (obligations + Local Law calendar + equipment + cost rollup), board-by-state kanban.

## 7. Open questions (decisions pending)

1. Unified vs. split obligation table (one table + discriminator vs. two behind a view).
2. Building attributes — sourced from NYC datasets (PLUTO) as derived, or maintained manually as authoritative.
3. `recurrence_config` as jsonb vs. normalized columns.
4. OATH entity resolution — dedicated `match_candidate` structure vs. inline.
5. Permissions model for external parties + note visibility (near-future).
6. ERP integration direction — push estimates as commitments, or pull posted actuals only.
7. UI: proof checklist collapse-when-complete; reconciliation inline vs. portfolio "exceptions" view; dashboard grouping toggle.

## 8. Reference data (verified during design)

**HPD violation classes / correction windows**
- Class A (non-hazardous): 90 days · Class B (hazardous): 30 days · Class C (immediately hazardous): 24 hours.
- Class C exceptions: lead-based paint & window guards = 21 days; heat & hot water = immediate ($250/day, ERP-eligible). Class I = information orders, administratively issued.
- Certification (eCert or paper) within the NOV window; lead is **not** eCertifiable; mold/vermin in AEP buildings not eCertifiable; property registration must be current to certify.
- Non-lead: deemed complied 70 days after HPD receives certification if no re-inspection. Lead requires verification.
- Recovery: Dismissal Request (past certification period); Reissuance (> 12 months old).
- Lead order numbers: 616 (presumed lead — contestable via testing); 618 (lead-poisoned child — extra records).

**Major Local Laws (proactive obligations)**
- LL84 benchmarking (≥25,000 sq ft, annual May 1) · LL97 emissions (≥25,000 sq ft, annual, ~$268/ton over limit) · FISP/LL11 façade (>6 stories, 5-yr sub-cycles by block-number last digit) · LL152 gas (community-district cycle) · LL126/PIPS parking (6-yr cycles) · parapet (annual Dec 31) · LL87 energy audit (Dec 31) · LL88 lighting/submetering · LL33/95 energy grade (October) · boiler/elevator (annual via DOB NOW) · LL55/LL31 lead (annual, pre-1960 with child <6). Many filings are DOB NOW digital-only.

**Data sources**
- HPD violations: `data.cityofnewyork.us/.../wvxf-dwi5` (Socrata SODA).
- OATH case status: `data.cityofnewyork.us/.../jz4z-kudi` — NOTE: respondent name/street/city/state fields were removed May 4, 2026, so summons→building matching must use BBL/BIN + remaining location fields (fuzzy matching likely).
- Local Law filings: DOB NOW: Safety, EPA Portfolio Manager (LL84), DOB emissions platform (LL97).

## 9. Files in this project

- `Compliance-Tracker-Data-Model.md` — data model spec (v0.2).
- `Compliance-Tracker-UI-Wireframes.md` — screen wireframes & components.
- `HPD-Violation-Workflows.md` — per-class HPD remediation workflows (reference / state-machine source).
- `README.md` — this file.

## 10. Next steps (where to pick up)

- Resolve the open questions in §7 — especially #1 (table structure) and #2 (building attributes), which most affect infrastructure.
- Draft `obligation_rule` seed rows (one per Local Law, with applicability predicate + recurrence config) so the generator has concrete inputs.
- Sketch the building view and/or board-by-state UI.
- Begin infrastructure design once the table-structure question is settled.

---
*Design captured as of the latest session. All numbers/dates above were current as of mid-2026; re-verify NYC fees, deadlines, and dataset fields against official HPD/DOB/OATH sources before building.*
