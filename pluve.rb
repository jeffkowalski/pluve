#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

# Configuration constants
BASELINE_MINUTES = 5      # Minutes before valve activation to establish baseline
RAMP_UP_MINUTES = 2       # Minutes to skip after valve turns on (reduced for shorter runtimes)
MIN_VALVE_RUNTIME = 6     # Minimum minutes for a valve run to be analyzed (just below your 8min minimum)
FLOW_INCREASE_THRESHOLD = 0.1 # GPM increase to consider valve-related flow

class Pluve < RecorderBotBase
  no_commands do

    def main
      ospi_client  = new_influxdb_client('ospi')
      flume_client = new_influxdb_client('flume')
      pluve_client = new_influxdb_client('pluve')

      # Determine lookback period based on run frequency
      # For 6-day irrigation schedule, look back 26-30 hours to ensure we catch
      # the most recent complete irrigation cycle
      lookback_hours = ENV['PLUVE_LOOKBACK_HOURS']&.to_i || 30
      lookback_start = Time.now - (lookback_hours * 3600)

      # Get valve events from specified time window
      results = ospi_client.query "select * from valves where time >= '#{lookback_start.iso8601}'"
      if results.nil? || results.first.nil?
        @logger.warn 'no ospi data to inspect'
        return
      end

      valve_events = parse_valve_events(results.first['values'])
      flow_data = []
      baseline_data = []

      valve_events.each do |event|
        next if event[:duration_minutes] < MIN_VALVE_RUNTIME

        @logger.debug "Processing valve #{event[:valve]}: #{event[:duration_minutes]} minutes"

        # Get baseline flow before valve activation
        baseline_flow = get_baseline_flow(flume_client, event[:on_time], BASELINE_MINUTES)
        next unless baseline_flow

        # Get flow during valve operation (excluding ramp-up period)
        valve_flow = get_valve_flow(flume_client, event[:on_time], event[:off_time], RAMP_UP_MINUTES)
        next unless valve_flow

        # Calculate flow metrics
        metrics = calculate_flow_metrics(baseline_flow, valve_flow, event)

        # Only include if we detected actual valve-related flow increase
        if metrics[:net_flow_increase] > FLOW_INCREASE_THRESHOLD
          flow_data.concat(create_flow_data_points(valve_flow, event[:valve]))
          baseline_data.push(create_baseline_data_point(metrics, event[:valve]))
        else
          @logger.warn "Valve #{event[:valve]} showed no significant flow increase - possible malfunction or background usage interference"
        end
      end

      # Write processed data
      pluve_client.write_points flow_data, 's' unless flow_data.empty?
      pluve_client.write_points baseline_data, 's' unless baseline_data.empty?

      # Calculate and store anomaly detection metrics
      update_anomaly_metrics(pluve_client)
    end

    private

    def parse_valve_events(valve_data)
      events = []
      current_valve = nil
      on_time = nil

      valve_data.each do |item|
        time = Time.iso8601(item['time'])
        value = item['value']

        if value.positive?
          # Valve turning on
          if current_valve
            @logger.error "out-of-sequence: valve #{value} turned on but valve #{current_valve} was still on at #{time}"
          end
          current_valve = value
          on_time = time
        else
          # Valve turning off
          if current_valve && on_time
            off_time = time
            duration_minutes = (off_time - on_time) / 60.0

            # Validate sequence and timing for irrigation program
            validate_irrigation_sequence(current_valve, on_time, duration_minutes)

            events.push({
              valve: current_valve,
              on_time: on_time,
              off_time: off_time,
              duration_minutes: duration_minutes
            })

            @logger.debug "Valve #{current_valve}: #{duration_minutes.round(1)} minutes"
          else
            @logger.error "out-of-sequence: valve turned off but no valve was on at #{time}"
          end

          current_valve = nil
          on_time = nil
        end
      end

      events
    end

    def validate_irrigation_sequence(valve, start_time, duration)
      # Check if this looks like part of the regular 3am program
      hour = start_time.hour

      # Expected start times for each valve (3am + valve delays)
      # Valve 1 starts at 3:00am, each subsequent valve starts 18-30 min later (valve runtime + 10 min pause)
      expected_start_hour = 3 + ((valve - 1) * 18) / 60  # Conservative estimate using min runtime

      if hour >= 3 && hour <= 18  # Reasonable irrigation window
        if duration < 6 || duration > 25  # Outside expected range (allowing for weather adjustments)
          @logger.warn "Valve #{valve} ran for #{duration.round(1)} minutes - outside normal 8-20 minute range"
        end
      else
        @logger.info "Valve #{valve} ran outside normal program hours at #{start_time.strftime('%H:%M')}"
      end
    end

    def get_baseline_flow(flume_client, valve_on_time, baseline_minutes)
      baseline_start = valve_on_time - (baseline_minutes * 60)
      baseline_end = valve_on_time

      query = "select value from flow where time > '#{baseline_start.iso8601}' and time < '#{baseline_end.iso8601}'"
      results = flume_client.query query

      return nil if results.empty? || results.first['values'].empty?

      results.first['values'].map { |r| r['value'].to_f }
    end

    def get_valve_flow(flume_client, on_time, off_time, ramp_up_minutes)
      # Skip the ramp-up period
      flow_start = on_time + (ramp_up_minutes * 60)
      return nil if flow_start >= off_time

      query = "select value from flow where time > '#{flow_start.iso8601}' and time < '#{off_time.iso8601}'"
      results = flume_client.query query

      return nil if results.empty? || results.first['values'].empty?

      flow_data = results.first['values'].map do |rate|
        {
          time: Time.iso8601(rate['time']),
          value: rate['value'].to_f
        }
      end

      # Filter out obvious outliers (more than 3 standard deviations from median)
      values = flow_data.map { |d| d[:value] }
      median = values.sort[values.length / 2]
      std_dev = Math.sqrt(values.map { |v| (v - median) ** 2 }.sum / values.length)

      flow_data.select { |d| (d[:value] - median).abs <= 3 * std_dev }
    end

    def calculate_flow_metrics(baseline_flow, valve_flow, event)
      baseline_median = baseline_flow.sort[baseline_flow.length / 2]
      baseline_mean = baseline_flow.sum / baseline_flow.length.to_f
      baseline_std = Math.sqrt(baseline_flow.map { |v| (v - baseline_mean) ** 2 }.sum / baseline_flow.length)

      valve_values = valve_flow.map { |d| d[:value] }
      valve_median = valve_values.sort[valve_values.length / 2]
      valve_mean = valve_values.sum / valve_values.length.to_f
      valve_max = valve_values.max
      valve_std = Math.sqrt(valve_values.map { |v| (v - valve_mean) ** 2 }.sum / valve_values.length)

      # Calculate net flow increase
      net_flow_increase = valve_median - baseline_median
      flow_stability = valve_std / valve_mean  # coefficient of variation

      {
        baseline_median: baseline_median,
        baseline_mean: baseline_mean,
        baseline_std: baseline_std,
        valve_median: valve_median,
        valve_mean: valve_mean,
        valve_max: valve_max,
        valve_std: valve_std,
        net_flow_increase: net_flow_increase,
        flow_stability: flow_stability,
        duration_minutes: event[:duration_minutes]
      }
    end

    def create_flow_data_points(valve_flow, valve_number)
      valve_flow.map do |data_point|
        {
          series: 'flow',
          values: { value: data_point[:value] },
          tags: { valve: format('%02d', valve_number) },
          timestamp: InfluxDB.convert_timestamp(data_point[:time], 's')
        }
      end
    end

    def create_baseline_data_point(metrics, valve_number)
      {
        series: 'valve_metrics',
        values: {
          baseline_median: metrics[:baseline_median],
          valve_median: metrics[:valve_median],
          valve_max: metrics[:valve_max],
          net_flow_increase: metrics[:net_flow_increase],
          flow_stability: metrics[:flow_stability],
          duration_minutes: metrics[:duration_minutes]
        },
        tags: { valve: format('%02d', valve_number) }
      }
    end

    def update_anomaly_metrics(pluve_client)
      # Calculate statistics for each valve over different time windows
      time_windows = ['7d', '30d', '90d']

      time_windows.each do |window|
        # Get flow metrics for each valve
        metrics_query = "select mean(net_flow_increase), stddev(net_flow_increase), " \
                       "mean(valve_max), stddev(valve_max), " \
                       "mean(flow_stability), stddev(flow_stability) " \
                       "from valve_metrics where time > now()-#{window} group by valve"

        results = pluve_client.query metrics_query
        next if results.empty?

        anomaly_data = []
        results.each do |valve_stats|
          valve_num = valve_stats['tags']['valve']
          values = valve_stats['values'][0]

          # Calculate multiple anomaly scores
          flow_z_score = calculate_z_score(
            values['mean'], values['stddev'],
            get_valve_population_mean(results, 'mean'),
            get_valve_population_stddev(results, 'mean')
          )

          max_flow_z_score = calculate_z_score(
            values['mean_1'], values['stddev_1'],
            get_valve_population_mean(results, 'mean_1'),
            get_valve_population_stddev(results, 'mean_1')
          )

          stability_z_score = calculate_z_score(
            values['mean_2'], values['stddev_2'],
            get_valve_population_mean(results, 'mean_2'),
            get_valve_population_stddev(results, 'mean_2')
          )

          anomaly_data.push({
            series: 'anomaly_scores',
            values: {
              flow_z_score: flow_z_score,
              max_flow_z_score: max_flow_z_score,
              stability_z_score: stability_z_score,
              composite_score: [flow_z_score.abs, max_flow_z_score.abs, stability_z_score.abs].max
            },
            tags: {
              valve: valve_num,
              window: window
            }
          })
        end

        pluve_client.write_points anomaly_data, 's' unless anomaly_data.empty?
      end
    end

    def calculate_z_score(value, std_dev, population_mean, population_std)
      return 0.0 if population_std.nil? || population_std.zero?
      (value - population_mean) / population_std
    end

    def get_valve_population_mean(results, field)
      values = results.map { |r| r['values'][0][field] }.compact
      values.sum / values.length.to_f
    end

    def get_valve_population_stddev(results, field)
      values = results.map { |r| r['values'][0][field] }.compact
      mean = values.sum / values.length.to_f
      Math.sqrt(values.map { |v| (v - mean) ** 2 }.sum / values.length)
    end
  end
end

Pluve.start
