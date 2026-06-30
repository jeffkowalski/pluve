# Pluve — irrigation flow analysis

**Purpose:** detect abnormal water flow on each irrigation valve (station) — a
broken, stuck, blocked, or mis-wired valve — by correlating the **OpenSprinkler**
controller's valve on/off events with the **Flume** whole-house water meter's
flow readings, one run at a time.

This README is written as a map for a future Claude (or human) picking this up
cold. It describes Pluve *and* every system it touches, because Pluve is a
middle stage in a pipeline and is meaningless in isolation.

---

## The big picture

```
  ┌──────────────────┐         ┌──────────────────┐
  │  OpenSprinkler   │  valve  │   Flume meter    │  whole-house
  │  controller      │  on/off │   (cloud API)    │  flow, 1/min
  │  (ospi.local)    │         │                  │
  └────────┬─────────┘         └─────────┬────────┘
           │ HTTP web iface              │ flume.rb  (cron */10 min)
           ▼                             ▼
   InfluxDB `ospi`                InfluxDB `flume`
   measurement: valves            measurement: flow
   (valve# when on, 0 off)        (gallons/min ≈ GPM, @ XX:00:00)
           │                             │
           └──────────────┬──────────────┘
                          ▼  pluve.rb  (cron 21:00 daily)
                  InfluxDB `pluve`
                  ├ valve_metrics  (one point per valve run)
                  └ flow           (raw per-minute samples, tagged by valve)
                          │
            ┌─────────────┴──────────────┐
            ▼                            ▼
   sauron.rb (cron */15 min)     Grafana (cube.local:3000)
   TestPluve → org-mode TODOs    dashboard `pluve-irrigation-001`
   in ~/Dropbox/workspace/        (InfluxQL panels on the
   org/sauron.org                  `pluve` datasource)
```

Everything runs on **cube.local**. All bots are scheduled from
`crontab -l` on cube and share the **botbase** framework.

---

## The pipeline, stage by stage

### 1. OpenSprinkler → `ospi` database
- **Producer:** the OpenSprinkler irrigation controller (`ospi.local`, firmware
  source at `~/Dropbox/workspace/motes/OpenSprinkler-firmware`). It writes valve
  on/off events **directly to the `ospi` InfluxDB database through a call to its
  own HTTP web interface** — there is no MQTT broker or separate bridge involved.
- **What Pluve reads:** measurement **`valves`** — a single time series whose
  `value` is the **station number** when a valve turns on and **0** when it turns
  off. Events are at second resolution and the controller runs stations
  **sequentially** with a station delay (~10 min observed) between them.
- The `ospi` DB also has `station00..station72` and `valve01..valve201`
  measurements — these are legacy/experimental; **`valves` is the canonical one.**
- The controller can also be queried live at `http://ospi.local:8080/jo?pw=...`
  (used by sauron to detect weather-skip / watering-level 0%).

### 2. Flume → `flume` database  (`~/Dropbox/workspace/bots/flume/flume.rb`)
- **Schedule:** cron every 10 minutes (`record-status`), each run catching up the
  last ~18 hours.
- Calls the Flume cloud API (`api.flumetech.com`) with `bucket: MIN`, writing
  measurement **`flow`**, field `value` = **gallons used in that minute**
  (numerically ≈ average GPM). Credentials in `~/.credentials/flume.yaml`.
- **Critical timing fact:** a Flume sample timestamped `T` reports flow over the
  interval **`[T, T+60)`** (forward-looking, aligned to wall-clock `XX:00:00`).
  Pluve depends on this convention for its overlap math.

### 3. Pluve → `pluve` database  (this repo — `pluve.rb`)
- **Schedule:** cron daily at 21:00 (`bundle exec ./pluve.rb`, default task
  `record_status` → `main`).
- **Lookback:** default 30 h (`PLUVE_LOOKBACK_HOURS` env overrides — used for
  backfill; the whole pipeline is idempotent, keyed by valve + run time).
- For each valve run in the lookback window it computes one **`valve_metrics`**
  point and writes the raw in-run Flume samples to **`flow`** (tagged by valve).
- See "How pluve.rb computes a run" below.

### 4. Sauron → org-mode TODOs  (`~/Dropbox/workspace/bots/sauron/sauron.rb`)
- **Schedule:** cron every 15 minutes. Sauron is a general home-monitoring
  scanner with ~25 checks (hosts, backups, git repos, power, Tesla, etc.); the
  **`TestPluve`** class is the irrigation watchdog.
- `TestPluve` reads `pluve.valve_metrics` and emits alerts as `*** TODO` entries
  in `~/Dropbox/workspace/org/sauron.org`. See "Detection logic" below.

### 5. Grafana → dashboards  (cube.local:3000, v13.x)
- Dashboard **`pluve-irrigation-001`** ("Pluve Irrigation Monitoring") visualises
  the metrics. Datasource **`pluve`** (uid `r_ofO_IMk`, type influxdb).
- **InfluxDB is 1.12.4 → all queries are InfluxQL, never Flux.** The datasource
  must be InfluxQL with db `pluve`. `grafana.db` is root/grafana-owned (no
  passwordless sudo for jeff); edit dashboards through the HTTP API with a
  service-account token, not by touching the DB.

---

## Shared infrastructure

- **botbase** (`~/Dropbox/workspace/bots/botbase`): base classes every bot
  inherits via a Gemfile git dependency. `RecorderBotBase` (default task
  `record-status`) for collectors like pluve/flume; `ScannerBotBase` (`scan`) for
  notifiers like sauron. Provides `new_influxdb_client(db)`, `with_rescue`,
  `load_credentials`, logging to `~/.log/<bot>.log`, and the `--dry-run`/`--log`/
  `--verbose` options.
- **InfluxDB 1.12.4** on `cube.local:8086`. One database per data source (ospi,
  flume, pluve, kasa, tesla, teg, nest, sunpower, pvs, withings, …). HTTP API;
  credentials in `~/.credentials/influx.yaml`.
- **Cron on cube.local** runs all bots (`ssh cube.local crontab -l`).
- **Credentials:** `~/.credentials/*.yaml` (mode 600; sauron's `TestCredentials`
  enforces this).

---

## How `pluve.rb` computes a run

For each `[on_time, off_time]` valve run (parsed from `ospi.valves` transitions):

1. **Baseline** = median Flume flow in a quiet window before the run
   (`on - 240s … on - 60s`; the 60 s guard skips the partial bucket the valve
   opens into). A symmetric **after** window is also measured; `baseline_quiet`
   is true only if both are clean. The ~10 min station delay normally guarantees
   these windows are quiet.
2. **Delivered flow (the headline metric)** =
   `Σ(Flume buckets overlapping the run) / duration_minutes − baseline`.
   This **volume-integration** approach is robust to short runs and sub-minute
   misalignment: a boundary bucket already holds only its partial in-run volume,
   so no "ramp-up" trimming is needed. (Flow actually reaches full rate within
   the first whole minute — the low edge samples are *bucket-alignment artifacts*,
   not physical ramp.)
3. **Steady CV / median** are computed only from *interior* full-minute buckets
   and only when there are ≥4 of them (otherwise omitted — short runs don't get
   bogus stability numbers).
4. **Every run is written** (including ~0-flow runs), each tagged by valve and
   **timestamped at its real `on_time`**, with quality flags `flow_detected`
   (delivered ≥ 0.5 GPM) and `baseline_quiet`.

Key constants live at the top of `pluve.rb` (`BUCKET_SECONDS`,
`BASELINE_WINDOW_SECONDS`, `BASELINE_GUARD_SECONDS`, `MIN_INTERIOR_FOR_STEADY`,
`FLOW_FLOOR_GPM`, `QUIET_BASELINE_GPM`).

---

## Detection logic (`sauron.rb` → `TestPluve`)

The guiding principle: **a broken valve deviates from how _that valve_ normally
behaves — not from the other (physically very different) valves.** Detection is
per-valve, against its own history, robust (median + MAD modified z-score), and
**persistence-based** (it ignores single-run flukes).

- `check_no_flow` — ≥2 no-flow runs (`flow_detected=false`) in the last 7 days
  → CRITICAL. This is the primary broken-valve signal.
- `check_flow_shift` — recent *median* delivered GPM vs the valve's prior
  history (≥`MIN_HISTORY` runs); fires only on a sustained shift (down = blockage,
  up = break/leak).
- `check_absence` — a known valve silent > 21 days.
- `check_leak` — fleet-wide median `baseline_gpm` > 0.5 GPM.
- `check_processing_lag` — no new data in > 30 h (unless OSPI reports weather-skip).

Constants/thresholds are at the top of the `TestPluve` class.

---

## Database reference

| DB | measurement | key fields / tags | written by |
|----|-------------|-------------------|------------|
| `ospi` | `valves` | `value` = station# (on) / 0 (off) | OpenSprinkler |
| `flume` | `flow` | `value` = gal/min (@ `XX:00:00`, covers `[T,T+60)`) | flume.rb |
| `pluve` | `valve_metrics` | `delivered_gpm`, `gross_gpm`, `delivered_volume`, `duration_minutes`, `baseline_gpm`, `baseline_after_gpm`, `steady_median_gpm`, `steady_cv`, `n_interior`, `n_run_buckets`, `flow_detected`(bool), `baseline_quiet`(bool); tag `valve` (`%02d`); ts = `on_time` | pluve.rb |
| `pluve` | `flow` | `value` = raw in-run sample; tag `valve` | pluve.rb |

---

## Invariants — get these wrong and everything breaks

- **InfluxDB is 1.x → InfluxQL only.** No Flux.
- **Flume bucket `T` covers `[T, T+60)`.** Baselines must end ≥60 s before a
  valve opens; the run-overlap test is `T < off && T+60 > on`.
- **`valve_metrics` points are timestamped at the real run time** (`on_time`),
  tag = valve. Two runs of the same valve in one window get distinct timestamps;
  re-running pluve overwrites rather than duplicates (idempotent).
- Valves are **heterogeneous** — drip zones ~2–4 GPM, lawn zones ~18–26 GPM.
  Never compare valves to each other; always to their own history.

---

## History / gotchas (mistakes already made and fixed)

The original implementation produced ~33 false-positive alerts and missed real
faults. Root causes, all fixed:

1. **Cross-sectional anomaly score** (valve vs other valves) flagged the
   steadiest/largest/smallest valves as "aberrant." → Replaced with per-valve
   historical median+MAD. The old `anomaly_scores` measurement was **dropped**.
2. **No-flow runs were discarded** (only runs with flow increase > 0.1 were
   written), so the broken-valve case was invisible. → Now *every* run is
   written with quality flags.
3. **CV on 1–4 sparse samples** produced noise "partial blockage" alerts. →
   Steady CV only when ≥4 interior samples.
4. **`select last(*) … group by valve` returns `time = 1970-01-01`** in InfluxDB
   (wildcard aggregates zero the time column) → bogus "hasn't run in 20622 days."
   → Use `last(<field>)` / real timestamps.
5. **Batch write-timestamps** (all runs stamped at cron time) made temporal
   analysis impossible and risked silent overwrites. → Real `on_time` timestamps.
6. A stale **`z-score`** measurement (dead since 2025-09) was also **dropped**.
7. **MAD floor was fractional (5% of median), which scaled the wrong way.** Most
   valves are extremely precise (run-to-run MAD < 1% of flow), so a
   flow-proportional floor pinned every precise valve to a ~26%-of-flow detection
   threshold. A missing spray head on valve 26 (split driveway) raised flow ~10% —
   real, sustained, ~17× the valve's own noise — and went unalerted. → Floor
   changed to an **absolute** `MAD_FLOOR_GPM = 0.25` (a broken head adds a roughly
   fixed GPM regardless of zone size). Backtested clean (catch, zero false
   positives) over 0.12–0.40 GPM across all 30 valves / 90 days.

---

## Operations

```sh
# Run pluve manually (cron uses: cd .../pluve && bundle exec ./pluve.rb).
# If you cannot `cd` (sandbox), use BUNDLE_GEMFILE + absolute path:
ssh cube.local 'BUNDLE_GEMFILE=~/Dropbox/workspace/bots/pluve/Gemfile \
  bundle exec ~/Dropbox/workspace/bots/pluve/pluve.rb record-status --no-log -v'

# Backfill history (e.g. 100 days) — idempotent:
ssh cube.local 'PLUVE_LOOKBACK_HOURS=2400 BUNDLE_GEMFILE=~/Dropbox/workspace/bots/pluve/Gemfile \
  bundle exec ~/Dropbox/workspace/bots/pluve/pluve.rb record-status --no-log'

# Run just the irrigation watchdog:
ssh cube.local 'BUNDLE_GEMFILE=~/Dropbox/workspace/bots/sauron/Gemfile \
  bundle exec ~/Dropbox/workspace/bots/sauron/sauron.rb scan -o TestPluve --no-log'

# Query InfluxDB directly (read-only):
curl -s -G http://cube.local:8086/query --data-urlencode db=pluve \
  --data-urlencode 'q=SELECT last("delivered_gpm") FROM valve_metrics GROUP BY "valve"'

# Edit the Grafana dashboard: needs a service-account token (Editor) —
# POST /api/dashboards/db ; datasource uid r_ofO_IMk. grafana.db is not jeff-readable.
```

---

## Validation story (why we trust this)

Backfilling 100 days surfaced a real fault the old system had silently dropped:
**station 5 delivered 0.0 GPM from 2026-04-18 to 2026-05-05**, while all 27 other
valves flowed normally (so it wasn't the meter). The `roam` daily for 2026-05-06
records *"squirrel had chewed through fat red wire for valve 5 … repaired it"* —
a wiring fault, exactly what `check_no_flow` reports. Flow resumed 2026-05-09
(first run after the repair). Simulating the new detector mid-outage fires
*"valve 5 no flow on 6 of 6 runs."* The data even supplied the outage onset the
diary lacked.

A second, opposite fault confirmed the *upper* side of the detector:
**station 26 (split driveway) stepped from ~23.1 to ~25.4 GPM on 2026-06-20** and
held there — a missing spray head adding ~10% flow. The original 5% MAD floor was
blind to it (gotcha 7); the absolute 0.25 GPM floor catches it as
*"valve 26 flow shifted up to 25.4 GPM"* with no false positives elsewhere.

---

## File / location index

| Thing                      | Where                                                     |
|----------------------------|-----------------------------------------------------------|
| Pluve bot                  | `~/Dropbox/workspace/bots/pluve/pluve.rb`                 |
| Flume collector            | `~/Dropbox/workspace/bots/flume/flume.rb`                 |
| Sauron monitor (TestPluve) | `~/Dropbox/workspace/bots/sauron/sauron.rb`               |
| Shared base classes        | `~/Dropbox/workspace/bots/botbase/lib/botbase/botbase.rb` |
| OpenSprinkler firmware     | `~/Dropbox/workspace/motes/OpenSprinkler-firmware`        |
| Alert output               | `~/Dropbox/workspace/org/sauron.org`                      |
| InfluxDB / Grafana host    | `cube.local`, ports 8086 / 3000                           |
| Logs                       | `~/.log/<bot>.log` (on cube)                              |
