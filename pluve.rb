#!/usr/bin/env ruby
# frozen_string_literal: true

require 'influxdb'
require 'time'


ospi_client = InfluxDB::Client.new url: 'http://carbon.local:8086/ospi'
flume_client = InfluxDB::Client.new url: 'http://carbon.local:8086/flume'
pluve_client = InfluxDB::Client.new url: 'http://carbon.local:8086/pluve'

data = []
results = ospi_client.query 'select * from valves where time >= now()-25h'
valve = nil
on = nil
off = nil
results.first['values'].each do |item|
  time = item['time']
  value = item['value']
  if value.positive?
    valve = value
    on = time
    off = nil
  else
    if valve
      off = time
      results = flume_client.query "select value from flow where time >= '#{on}' and time <= '#{off}'"
      if results.count.positive?
        results.first['values'].each do |rate|
          time = Time.iso8601(rate['time'])
          data.push({ series: 'flow',
                      values: { value: rate['value'].to_f },
                      tags: { valve: format('%<valve>02d', valve: valve) },
                      timestamp: InfluxDB.convert_timestamp(time, 's') })
        end
      end
    else
      puts 'OUT OF SEQUENCE'
    end
    on = nil
    off = nil
    valve = nil
  end
end

pluve_client.write_points data, 's'
