#!/usr/bin/env ruby

require 'rubygems'
require 'json'
require 'graphite_graph'
require 'net/http'
require 'uri'
require 'optparse'
require 'pp'

def status_exit(msg, code)
  puts msg
  exit code
end

class ValueChecker
  # Return the list of failures
  def check(data)
    raise "Not implemented"
    return ["fail1", "fail2"]
  end
end

class ConstantValueChecker < ValueChecker
  attr_accessor :min, :max
  
  def initialize(min, max)
    if min == nil and max == nil
      raise(ArgumentError, "max or min must have value")
    end
    # If min and max are the same, set only a value, setting it as min
    if min == max
      if min < 0 then
        max = nil
      else 
        min = nil
      end
    end
    @min = min
    @max = max
  end

  def check(data, target_name=nil)
    target_data = data.reject {|x| not (x.is_a? Float or x.is_a? Integer)}
    target_max = target_data.max
    target_min = target_data.min

    fails = []
    if min and (target_min <= min)
      fails << "#{target_name} #{target_min} <= #{min}"
    end
    if max and (target_max >= max)
      fails << "#{target_name} #{target_max} >= #{max}"
    end
    fails
  end
end

class DataValueChecker < ValueChecker
  attr_accessor :threshold_data, :name, :type
  
  def initialize(threshold_data, name, type, check_number)
    if threshold_data == nil
      raise(ArgumentError, "Missing threshold data '#{name}'")
    end
    # Get the first not null point as a first "last_value"
    if (last_value = threshold_data.find { |x| not x.nil? }) == nil
      raise(ArgumentError, "Missing threshold data '#{name}'")
    end
    
    # Remove nulls
    @threshold_data = (0..(check_number-1)).map { |index|
      last_value = threshold_data[index] || last_value  
    }
    @name = name
    @type = type
  end

  def check(data, target_name=nil)
    
    fails = []
    data.each_with_index { |value, index|
      case type 
      when :min
        if threshold_data[index] and value <= threshold_data[index]
          fails << "#{target_name}:#{value} <= #{name}:#{threshold_data[index]}"
          break
        end  
      when :max
        if threshold_data[index] and value >= threshold_data[index]
          fails << "#{target_name}:#{value} >= #{name}:#{threshold_data[index]}"
          break
        end
      end  
    }            
    fails
  end
end

def parse_options
  # Default values
  options = {
    :crits => [],
    :warns => [],
    :threshold_fields => [ "crit_0", "crit_1", "warn_0", "warn_1"],
    :check_data => {},
    :url => "http://localhost/render/?",
    :check_number => 3,
    :overrides => {},
    :override_aliases => false,
    :thresholds => {
      :critical => {:max => [], :min => []},
      :warning => {:max => [], :min => []}
    }
  }

  opts = OptionParser.new do |opts|
    opts.banner =
    %Q{Usage:

 #{$0} [options]

Check the data on graphite

Options:
    }

    opts.on("--graphite URL", "Base URL for the Graphite installation") do |v|
      options[:url] = v
    end

    opts.on("--graph GRAPH", "Graph defintition") do |v|
      options[:graph] = v
      unless options[:graph] && File.exists?(options[:graph])
        raise OptionParser::InvalidOption.new("Can't find graph defintion #{options[:graph]}")
      end
    end

    opts.on("--warning WARNING", Float, "Warning threshold, can be specified multiple times") do |v|
      options[:warns] << Float(v)
    end

    opts.on("--warning-max WARNING", Float, "Maximum warning threshold") do |v|
      options[:warn_max] = Float(v)
    end

    opts.on("--warning-min WARNING", Float, "Minimun warning threshold") do |v|
      options[:warn_min] = Float(v)
    end

    opts.on("--critical CRITICAL", Float, "Critical threshold, can be specified multiple times") do |v|
      options[:crits] << Float(v)
    end

    opts.on("--critical-max CRITICAL", Float, "Maximum critical threshold") do |v|
      options[:crit_max] = Float(v)
    end

    opts.on("--critical-min CRITICAL", Float, "Minimun critical threshold") do |v|
      options[:crit_min] = Float(v)
    end

    opts.on("--check NUMBER", Integer, "Number of past data items to check") do |v|
      options[:check_number] = v
    end

    opts.on("--critical-max-field [FIELD]", "Use the a graph field as critical maximum (default crit_0). Can be repeated.") do |v|
      options[:thresholds][:critical][:max] << v || "crit_0"
      options[:threshold_fields] << v if v 
    end

    opts.on("--critical-min-field [FIELD]", "Use the a graph field as critical minimun (default crit_1). Can be repeated.") do |v|
      options[:thresholds][:critical][:min] << v || "crit_0"
      options[:threshold_fields] << v if v 
    end

    opts.on("--warning-max-field [FIELD]", "Use the a graph field as warning maximum (default crit_0). Can be repeated.") do |v|
      options[:thresholds][:warning][:max] << v || "crit_0"
      options[:threshold_fields] << v if v 
    end

    opts.on("--warning-min-field [FIELD]", "Use the a graph field as warning minimun (default crit_1). Can be repeated.") do |v|
      options[:thresholds][:warning][:min] << v || "crit_0"
      options[:threshold_fields] << v if v 
    end

    opts.on("--property key1=value1[,value2]", "Override the property key1 with the given value or list of values") do |v|
      key, value = v.split('=', 2)
      raise OptionParser::InvalidArgument.new('Value is empty') if (value == nil or value.empty?)

      key.strip!
      value.strip!

      if value.include? ','
        value = value.split(',').map { |x| x.strip }
      end
      options[:overrides][key.to_sym] = value
    end

    opts.on("--include field1,field2,field3", Array, "Only check the listed fields") do |list|
      options[:include] = list
    end

    opts.on("--exclude field1,field2,field3", Array, "Exclude listed fields") do |list|
      options[:exclude] = list
    end

    opts.on("--[no-]override-aliases", "Override field aliases with field id (default false)") do |v|
      options[:override_aliases] = v
    end
  end
  begin
    opts.parse!
    options[:argv] = ARGV
  rescue OptionParser::ParseError, OptionParser::InvalidOption => err
    status_exit "UNKNOWN - #{err}", 3
  end

  options
end

def init_graphite(options)
  graphite = GraphiteGraph.new(options[:graph], options[:overrides])

  # Override aliases with the target_id if desired
  # It is done here to avoid modify the graphite_graph code and
  # allow use this plugin with the original gem.
  if options[:override_aliases]
    graphite.targets.each { |name, attrs|
      unless attrs[:alias] =~ /(warn|crit)_[01]$/ 
        attrs[:alias] = name
      end 
    }
  end

  graphite
end

def load_graphite(graphite, options)
  uri = URI.parse("%s?%s" % [ options[:url], graphite.url(format = :json) ])
  # Try to get the data
  data = []
  begin
    json = Net::HTTP.get_response(uri)
    status_exit("UNKNOWN - Could not request graph data for HTTP code #{json.code}", 3) unless json.code == "200"
    data = JSON.load(json.body)
  rescue Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
  Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError => e
    status_exit "UNKNOWN - Can't get graph:  #{e.message}", 3
  end

  check_data = {}
  threshold_data = {}

  data.each do |d|
    if options[:threshold_fields].include?(d["target"])
      threshold_data[ d["target"] ] = d["datapoints"].last(options[:check_number]).map{|i| i.first}
    else
      next if options[:include] and not options[:include].include?(d["target"])
      next if options[:exclude] and options[:exclude].include?(d["target"])
      check_data[ d["target"] ] = d["datapoints"].last(options[:check_number]).map{|i| i.first}
    end
  end

  if check_data.empty?
    status_exit "UNKNOWN: Graph does not have Data", 3
  end

  [check_data, threshold_data]
end

def generate_checks(options, graphite, check_data, threshold_data)
  checks = { :critical => [], :warning => []}

  crit_constant_max = options[:crit_max] || (options[:crits] || graphite.critical_threshold).max || nil
  crit_constant_min = options[:crit_min] || (options[:crits] || graphite.critical_threshold).min || nil
  warn_constant_max = options[:warn_max] || (options[:warns] || graphite.critical_threshold).max || nil
  warn_constant_min = options[:warn_min] || (options[:warns] || graphite.critical_threshold).min || nil

  if (crit_constant_min or crit_constant_max)
    checks[:critical] << ConstantValueChecker.new(crit_constant_min, crit_constant_max)
  end
  if (warn_constant_min or warn_constant_max)
    checks[:warning] << ConstantValueChecker.new(warn_constant_min, warn_constant_max)
  end
  [[:critical,:max], [:critical,:min],[:warning,:max],[:warning,:min]].each { |level, type|
    options[:thresholds][level][type].each { |field| 
      checks[level] << DataValueChecker.new(threshold_data[field], field, type, options[:check_number])
    }
  }

  if checks[:critical].empty? and checks[:warning].empty?
    status_exit "UNKNOWN: Graph does not have Warning or Critical information to check", 3
  end

  checks
end

def do_check_data(data, checks)
  fails = []

  data.keys.each do |target|
    checks.each do |check|
      fails += check.check(data[target], target)
    end
  end

  fails
end

def print_and_exit(results, code)
  exitcodes = ["OK", "WARNING", "CRITICAL", "UNKNOWN"]

  msg = results.map do |r|
    if r.is_a? Hash
      "%s %s %s %s" % [r[:target], r[:item], r[:operator], r[:expected]]
    else
      r
    end
  end.join(", ")

  status_exit "%s - %s" % [exitcodes[code], msg], code
end

#-----------------------------------------------------------------------

options = parse_options
graphite = init_graphite(options)
check_data, threshold_data = load_graphite(graphite, options)

checks = generate_checks(options, graphite, check_data, threshold_data)


if not (results = do_check_data(check_data, checks[:critical])).empty?
  print_and_exit results, 2
elsif not (results = do_check_data(check_data, checks[:warning])).empty?
  print_and_exit results, 1
else
  status_exit "OK - All data within expected ranges", 0
end

