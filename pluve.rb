#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

class Pluve < RecorderBotBase
  no_commands do
    def main
      ospi_client  = new_influxdb_client('ospi')
      flume_client = new_influxdb_client('flume')
      pluve_client = new_influxdb_client('pluve')

      data = []
      results = ospi_client.query 'select * from valves where time >= now()-25h'
      if results.nil? || results.first.nil?
        @logger.warn 'no ospi data to inspect'
        return
      end
      valve = nil
      on = nil
      off = nil
      results.first['values'].each do |item|
        time = item['time']
        value = item['value']
        if value.positive?
          @logger.error "out-of-sequence: valve #{value} turned on but valve #{valve} was still on" unless valve.nil?
          valve = value
          on = time
          off = nil
        else
          if valve
            off = time
            @logger.debug "valve #{valve}: on = #{on}, off = #{off}"
            results = flume_client.query "select value from flow where time > '#{on}' and time < '#{off}'"
            # maybe drop first and last, or choose median value to avoid ramp-up and ramp-down sampling error from flume?
            if results.count.positive?
              results.first['values'].each do |rate|
                time = Time.iso8601(rate['time'])
                data.push({ series: 'flow',
                            values: { value: rate['value'].to_f },
                            tags:   { valve: format('%<valve>02d', valve: valve) },
                            timestamp: InfluxDB.convert_timestamp(time, 's') })
              end
            end
          else
            @logger.error "out-of-sequence: valve #{value} turned off but no valve was on"
          end
          on = nil
          off = nil
          valve = nil
        end
      end

      pluve_client.write_points data, 's'

      meanr   = pluve_client.query 'select mean(value)   from flow where time > now()-1w group by valve'
      stddevr = pluve_client.query 'select stddev(value) from flow group by valve'
      medianr = pluve_client.query 'select median(value) from flow group by valve'

      mean   = Array.new(33, 0)
      median = Array.new(33, 0)
      stddev = Array.new(33, 0)
      meanr.each  { |v| mean[v['tags']['valve'].to_i]   = v['values'][0]['mean'] }
      medianr.map { |v| median[v['tags']['valve'].to_i] = v['values'][0]['median'] }
      stddevr.map { |v| stddev[v['tags']['valve'].to_i] = v['values'][0]['stddev'] }

      data = []
      (1..32).each do |v|
        data.push({ series: 'z-score',
                    values: { value: (mean[v] - median[v]) / stddev[v] },
                    tags:   { valve: format('%<valve>02d', valve: v) } })
      end
      pluve_client.write_points data, 's'
    end
  end
end

Pluve.start
