#!/usr/bin/env ruby

require 'rubygems'
require 'json'
require 'graphite_graph'
require 'net/http'
require 'uri'
require 'optparse'
require 'pp'

crits = []
warns = []
check_data = {}
url = "http://localhost/render/?"
graph = nil
check_number = 3
overrides = {}
override_aliases = false

opt = OptionParser.new

opt.on("--graphite [URL]", "Base URL for the Graphite installation") do |v|
    url = v
end

opt.on("--graph [GRAPH]", "Graph defintition") do |v|
  graph = v
end

opt.on("--warning [WARN]", "Warning threshold, can be specified multiple times") do |v|
  warns << Float(v)
end

opt.on("--critical [CRITICAL]", "Critical threshold, can be specified multiple times") do |v|
  crits << Float(v)
end

opt.on("--check [NUM]", Integer, "Number of past data items to check") do |v|
  check_number = v
end

opt.on("--property key1=value1[,value2]", "Override the property key1 with the given value or list of values") do |v|
  key, value = v.split('=', 2)
  raise OptionParser::InvalidArgument.new('Value is empty') if (value == nil or value.empty?)  
  key.strip!
  value.strip!
  
  if value.include? ','
     value = value.split(',').map { |x| x.strip }
  end
  overrides[key.to_sym] = value
end

opt.on("--[no-]override-aliases", "Override field aliases with field id (default false)") do |v|
  override_aliases = v
end

opt.parse!

def status_exit(msg, code)
  puts msg
  exit code
end

unless (graph && File.exist?(graph))
  status_exit "UNKNOWN - Can't find graph defintion #{graph}", 3
end

def check_data(data, min, max)
  fails = []

  data.keys.each do |target|
    target_data = data[target].reject {|x| not (x.is_a? Float or x.is_a? Integer)}
    target_max = target_data.max
    target_min = target_data.min
    
    if min == max # we got just one value to compare against
      if min < 0
        # if the threshold is < 0 we check for values below the threshold but have no way to say that
        # critical / warning is above -0.5 for example unless you specify a 2 value band
        if (target_min <= min)
          fails << {:target => target, :item => target_min, :operator => "<=", :expected => min}
        end
      else
        if (target_max >= max)
          fails << {:target => target, :item => target_max, :operator => ">=", :expected => max}
        end
      end
    else # we have a range of values to compare against and the values must be between
      if (target_min <= min)
        fails << {:target => target, :item => target_min, :operator => "<=", :expected => min}
      end

      if (target_max >= max)
        fails << {:target => target, :item => target_max, :operator => ">=", :expected => max}
      end
    end
  end

  fails.empty? ? false : fails
end

def print_and_exit(results, code)
  exitcodes = ["OK", "WARNING", "CRITICAL", "UNKNOWN"]

  msg = results.map do |r|
    "%s %s %s %s" % [r[:target], r[:item], r[:operator], r[:expected]]
  end.join(", ")

  status_exit "%s - %s" % [exitcodes[code], msg], code
end


graphite = GraphiteGraph.new(graph, overrides)

if override_aliases
  graphite.targets.each { |name, attrs| attrs[:alias] = name }
end
uri = URI.parse("%s?%s" % [ url, graphite.url(format = :json) ])

json = Net::HTTP.get_response(uri)

status_exit("UNKNOWN - Could not request graph data for HTTP code #{json.code}", 3) unless json.code == "200"

data = JSON.load(json.body)

data.each do |d|
  unless d["target"] =~ /(warn|crit)_[01]$/
    check_data[ d["target"] ] = d["datapoints"].last(check_number).map{|i| i.first}
  end
end

crits = graphite.critical_threshold if crits.empty? and graphite.critical_threshold
warns = graphite.warning_threshold if warns.empty? and graphite.warning_threshold

if crits.empty? || warns.empty? || check_data.empty?
  status_exit "UNKNOWN: Graph does not have Data, Warning and Critical information", 3
end

if results = check_data(check_data, crits.min, crits.max)
  print_and_exit results, 2

elsif results = check_data(check_data, warns.min, warns.max)
  print_and_exit results, 1

else
  status_exit "OK - All data within expected ranges", 0
end
