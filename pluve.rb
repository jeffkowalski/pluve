#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

# Pluve records, for every irrigation valve run, a robust set of flow metrics
# derived from the Flume water meter, so that aberrant flow (a broken, stuck,
# or blocked valve) can later be detected by comparing each valve to ITS OWN
# history.
#
# Data model and timing facts this code relies on (verified against raw data):
#   * Flume samples once per minute. A sample timestamped T reports the volume
#     (gallons, ~= average GPM) flowing during the interval [T, T+60).
#   * OpenSprinkler runs stations sequentially with a station delay (~10 min
#     observed), so the period immediately before/after a run is normally quiet
#     and usable as a baseline.
#   * Flow reaches full rate within the first complete minute: there is no slow
#     physical ramp. The low readings at a run's edges are PARTIAL-MINUTE
#     artifacts (the bucket only partly overlaps the run), not ramp-up.
#
# Because of the last point we do NOT skip a fixed "ramp" minute. Instead we
# integrate volume over the run: each boundary bucket already contains only the
# volume that actually flowed during its overlap with the run, so dividing total
# volume by the true run duration yields the correct average rate even for short
# runs and arbitrary sub-minute alignment.

# Flume sampling cadence, seconds. A bucket at time T covers [T, T+60).
BUCKET_SECONDS = 60

# A run shorter than this yields too little signal to bother recording.
MIN_VALVE_RUNTIME_MIN = 1.0

# Baseline = quiet flow just outside the run. We measure a window before (and,
# when the station gap allows, after) the run. GUARD seconds nearest the run are
# excluded because that boundary bucket overlaps the run itself.
BASELINE_WINDOW_SECONDS = 180 # 3 minutes of baseline samples
BASELINE_GUARD_SECONDS  = 60  # skip the minute adjacent to the valve transition

# Interior buckets are those fully inside the run (no partial-minute edge).
# CV / steady-state median are only meaningful with at least this many of them.
MIN_INTERIOR_FOR_STEADY = 4

# Quality thresholds (absolute GPM). These are deliberately loose; the real
# anomaly decision is made per-valve-against-its-own-history in the consumer.
FLOW_FLOOR_GPM     = 0.5 # delivered rate below this => effectively no flow
QUIET_BASELINE_GPM = 0.5 # baseline above this => not a clean baseline

class Pluve < RecorderBotBase
  no_commands do
    def main
      ospi_client  = new_influxdb_client('ospi')
      flume_client = new_influxdb_client('flume')
      pluve_client = new_influxdb_client('pluve')

      # For a multi-day irrigation schedule, look back far enough to catch the
      # most recent complete cycle. Idempotent: re-running overwrites the same
      # per-run points (keyed by valve + on_time), it does not duplicate them.
      lookback_hours = ENV['PLUVE_LOOKBACK_HOURS']&.to_i || 30
      lookback_start = Time.now - (lookback_hours * 3600)

      results = ospi_client.query "select * from valves where time >= '#{lookback_start.iso8601}'"
      if results.nil? || results.first.nil?
        @logger.warn 'no ospi data to inspect'
        return
      end

      events = parse_valve_events(results.first['values'])

      metric_points = []
      flow_points = []

      events.each_with_index do |event, idx|
        next if event[:duration_minutes] < MIN_VALVE_RUNTIME_MIN

        prev_off = idx.positive? ? events[idx - 1][:off_time] : nil
        next_on  = idx < events.length - 1 ? events[idx + 1][:on_time] : nil

        metrics = analyze_run(flume_client, event, prev_off, next_on)
        next unless metrics # no usable flume data at all

        metric_points.push(build_metric_point(metrics, event))
        flow_points.concat(build_flow_points(metrics[:run_buckets], event[:valve]))

        unless metrics[:flow_detected]
          @logger.warn "valve #{event[:valve]} ran #{event[:duration_minutes].round(1)} min but " \
                       "delivered only #{metrics[:delivered_gpm].round(2)} GPM - recorded as no-flow"
        end
      end

      unless options[:dry_run]
        pluve_client.write_points metric_points, 's' unless metric_points.empty?
        pluve_client.write_points flow_points, 's' unless flow_points.empty?
      end
      @logger.info "recorded #{metric_points.length} valve runs"
    end

    private

    # ---- valve event parsing -------------------------------------------------

    def parse_valve_events(valve_data)
      events = []
      current_valve = nil
      on_time = nil

      valve_data.each do |item|
        time = Time.iso8601(item['time'])
        value = item['value']

        if value.positive?
          @logger.error "out-of-sequence: valve #{value} on while valve #{current_valve} still on at #{time}" if current_valve
          current_valve = value
          on_time = time
        elsif current_valve && on_time
          events.push({ valve: current_valve,
                        on_time: on_time,
                        off_time: time,
                        duration_minutes: (time - on_time) / 60.0 })
          current_valve = nil
          on_time = nil
        else
          @logger.error "out-of-sequence: valve off but none was on at #{time}"
        end
      end

      events
    end

    # ---- per-run analysis ----------------------------------------------------

    # Returns a metrics hash, or nil if there is no usable flume data.
    def analyze_run(flume_client, event, prev_off, next_on)
      on  = event[:on_time]
      off = event[:off_time]
      duration_min = (off - on) / 60.0

      # One query spanning baseline-before .. baseline-after, sliced in Ruby.
      fetch_start = on - BASELINE_GUARD_SECONDS - BASELINE_WINDOW_SECONDS
      fetch_end   = off + BASELINE_GUARD_SECONDS + BASELINE_WINDOW_SECONDS
      buckets = fetch_flow(flume_client, fetch_start, fetch_end)
      return nil if buckets.empty?

      baseline_before = baseline_window(buckets, on - BASELINE_GUARD_SECONDS - BASELINE_WINDOW_SECONDS,
                                        on - BASELINE_GUARD_SECONDS, prev_off)
      baseline_after  = baseline_window(buckets, off + BASELINE_GUARD_SECONDS,
                                        off + BASELINE_GUARD_SECONDS + BASELINE_WINDOW_SECONDS, nil, next_on)

      # Use the before-baseline for subtraction; fall back to after if missing.
      baseline_gpm = baseline_before || baseline_after || 0.0

      # Buckets overlapping [on, off): a bucket at tb covers [tb, tb+60).
      run_buckets = buckets.select do |b|
        tb = b[:time].to_f
        tb < off.to_f && (tb + BUCKET_SECONDS) > on.to_f
      end
      return nil if run_buckets.empty?

      # Integrated volume: each boundary bucket already holds only its partial
      # in-run volume, so this is correct without trimming edges.
      delivered_volume = run_buckets.sum { |b| b[:value] }
      gross_gpm = delivered_volume / duration_min
      delivered_gpm = gross_gpm - baseline_gpm

      # Interior buckets fully inside the run: tb >= on AND tb+60 <= off.
      interior = run_buckets.select do |b|
        tb = b[:time].to_f
        tb >= on.to_f && (tb + BUCKET_SECONDS) <= off.to_f
      end
      interior_values = interior.map { |b| b[:value] }

      steady_median = steady_cv = nil
      if interior_values.length >= MIN_INTERIOR_FOR_STEADY
        steady_median = median(interior_values) - baseline_gpm
        mean = interior_values.sum / interior_values.length.to_f
        std  = Math.sqrt(interior_values.sum { |v| (v - mean)**2 } / interior_values.length)
        steady_cv = mean.positive? ? std / mean : 0.0
      end

      baseline_quiet = (baseline_before.nil? || baseline_before < QUIET_BASELINE_GPM) &&
                       (baseline_after.nil?  || baseline_after  < QUIET_BASELINE_GPM)

      { delivered_gpm: delivered_gpm,
        gross_gpm: gross_gpm,
        delivered_volume: delivered_volume,
        duration_minutes: duration_min,
        baseline_before_gpm: baseline_before,
        baseline_after_gpm: baseline_after,
        baseline_gpm: baseline_gpm,
        steady_median_gpm: steady_median,
        steady_cv: steady_cv,
        n_interior: interior_values.length,
        n_run_buckets: run_buckets.length,
        flow_detected: delivered_gpm >= FLOW_FLOOR_GPM,
        baseline_quiet: baseline_quiet,
        run_buckets: run_buckets }
    end

    # Median of flow within [start_t, end_t), clamped to stay clear of an
    # adjacent run (prev_off / next_on). Returns nil if no samples remain.
    def baseline_window(buckets, start_t, end_t, prev_off, next_on = nil)
      lo = start_t.to_f
      hi = end_t.to_f
      lo = [lo, prev_off.to_f].max if prev_off
      hi = [hi, next_on.to_f].min if next_on
      return nil if hi <= lo

      vals = buckets.select { |b| b[:time].to_f >= lo && b[:time].to_f < hi }.map { |b| b[:value] }
      vals.empty? ? nil : median(vals)
    end

    def fetch_flow(client, start_t, end_t)
      query = "select value from flow where time > '#{Time.at(start_t).utc.iso8601}' " \
              "and time < '#{Time.at(end_t).utc.iso8601}'"
      results = client.query query
      return [] if results.empty? || results.first['values'].empty?

      results.first['values'].map { |r| { time: Time.iso8601(r['time']), value: r['value'].to_f } }
    end

    # ---- influx point construction ------------------------------------------

    def build_metric_point(m, event)
      values = {
        delivered_gpm: m[:delivered_gpm],
        gross_gpm: m[:gross_gpm],
        delivered_volume: m[:delivered_volume],
        duration_minutes: m[:duration_minutes],
        baseline_gpm: m[:baseline_gpm],
        n_interior: m[:n_interior],
        n_run_buckets: m[:n_run_buckets],
        flow_detected: m[:flow_detected],
        baseline_quiet: m[:baseline_quiet]
      }
      values[:baseline_after_gpm] = m[:baseline_after_gpm] unless m[:baseline_after_gpm].nil?
      values[:steady_median_gpm]  = m[:steady_median_gpm]  unless m[:steady_median_gpm].nil?
      values[:steady_cv]          = m[:steady_cv]          unless m[:steady_cv].nil?

      { series: 'valve_metrics',
        values: values,
        tags: { valve: format('%02d', event[:valve]) },
        timestamp: InfluxDB.convert_timestamp(event[:on_time], 's') }
    end

    def build_flow_points(run_buckets, valve_number)
      run_buckets.map do |b|
        { series: 'flow',
          values: { value: b[:value] },
          tags: { valve: format('%02d', valve_number) },
          timestamp: InfluxDB.convert_timestamp(b[:time], 's') }
      end
    end

    # ---- statistics ----------------------------------------------------------

    def median(values)
      sorted = values.sort
      mid = sorted.length / 2
      sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end
  end
end

Pluve.start
