
require "rubygems"
require "activesupport"
require 'chronic'

class Array
  
  #
  # Return the lower boundary. (inside)
  #
  def bsearch_lower_boundary (range = 0 ... self.length, &block)
    lower  = range.first() - 1
    upper = if range.exclude_end? then range.last else range.last + 1 end
    while lower + 1 != upper
      mid = ((lower + upper) / 2).to_i # for working with mathn.rb (Rational)
      if yield(self[mid]) < 0
      	lower = mid
      else 
      	upper = mid
      end
    end
    return upper
  end

  #
  # This method searches the FIRST occurrence which satisfies a
  # condition given by a block in binary fashion and return the 
  # index of the first occurrence. Return nil if not found.
  #
  def bsearch_first (range = 0 ... self.length, &block)
    boundary = bsearch_lower_boundary(range, &block)
    if boundary >= self.length || yield(self[boundary]) != 0
      return nil
    else 
      return boundary
    end
  end
end

module LogSoul
  class Configuration
    def initialize(filename)
      @config = YAML.load(File.read(filename))
    end
    
    def log_files
      Dir[@config["log_files"]].map do |filename|
        LogFile.new(filename)
      end
    end
    
    def log_formats
      [LogFormat.new(@config["log_format"])]
    end
  end
  
  class LogFormat
    def initialize(log_format)
      @log_format = log_format
    end
    
    def regex
      Regexp.new(@log_format["regex"])
    end
    
    def bit_to_index
      return @bits if @bits
      bits = {}
      @log_format["captures"].each_with_index do |capture, i|
        bits[capture.intern] = i+1
      end
      @bits = bits
    end
    
    def timestamp_from_line(line, md = regex.match(line))
      unless md
        puts "couldn't match: #{line.inspect}"
        return nil
      end
      bits = bit_to_index
      time = Time.mktime(Time.now.year, 
                  md[bits[:month]], 
                  md[bits[:day]], 
                  md[bits[:hours]], 
                  md[bits[:minutes]], 
                  md[bits[:seconds]])
    end
    
    def decompose(line)
      unless md = regex.match(line)
        puts "couldn't match: #{line.inspect}"
        return nil
      end
      time = timestamp_from_line(line, md)
      {  :time => time, 
         :message => md[bit_to_index[:message]],
         :machine => md[bit_to_index[:machine]],
         :class => md[bit_to_index[:class]]}
    end
  end
  
  class LogFile
    attr_reader :filename
    
    def initialize(filename)
      @filename = filename
    end
    
    def index_of_first_line_before_time(log_format, time)
      lines.bsearch_lower_boundary do |line|
        timestamp = log_format.timestamp_from_line(line)
        timestamp <=> time
      end
    end
    
    def present_time(query, time)
      if query.start_time.day == query.end_time.day
        time.strftime("%X")
      else
        time.strftime("%x %X")
      end
    end
    
    def line_match?(query, info, line)
      query.matcher_args.all? {|arg| line =~ arg } and
        (!query.origin or info[:class] =~ query.origin)
    end
    
    def present_line(query, info, line)
      @class_width = [@class_width||0, info[:class].length].max
      out = present_time(query, info[:time]) + " | "
      out << info[:class].ljust(@class_width) + " | " + info[:message]
      out
    end
    
    def search(query)
      log_format = query.configuration.log_formats.first
      index = index_of_first_line_before_time(log_format, query.start_time)
      found_end = false
      until found_end
        line = lines[index]
        info = log_format.decompose(line)
        if line_match?(query, info, line)
          puts present_line(query, info, line)[0..120]
        end
        index += 1
        found_end = (info[:time] > query.end_time)
      end
    end
    
    def length
      %x{wc -l #{@filename}}.chomp.to_i
    end
    
    def lines
      @lines ||= File.readlines(@filename)
    end
    
    def touched
      File.mtime(@filename)
    end
  end
  
  class Query
    attr_reader :configuration
    
    def initialize(configuration, args)
      @configuration, @args = configuration, args
    end
    
    def start_time
      time_arg("from") || time_arg("start") || (Time.now - 5.minutes) 
    end
    
    def end_time
      time_arg("to") || time_arg("end") || Time.now
    end
    
    def origin
      @origin ||= origin1
    end
    
    def origin1
      @args.each do |arg|
        if arg =~ /--class=(.*)$/
          return Regexp.new($1)
        end
      end
      nil
    end
    
    def matcher_args
      @matcher_args ||= @args.reject {|arg| arg =~ /^--/}.map {|arg| Regexp.new(arg)}
    end
    
    def valid?
      errors.empty?
    end
    
    def errors
      errors = []
      if end_time < start_time
        errors << "  * start time (#{start_time}) is after end time (#{end_time})"
      end
      errors
    end
    
    private
    
    def time_arg(name)
      @args.each do |arg|
        if arg =~ /^--#{name}=(.*)$/
          time_string = $1
          if time_string =~ /^\d+\..*/
            return eval(time_string)
          else
            return Chronic.parse(time_string, :context => :past) + 1.day
          end
        end
      end
      nil
    end
  end
end

conf = LogSoul::Configuration.new("logsoul.yaml")
query = LogSoul::Query.new(conf, ARGV)
unless query.valid?
  puts "Invalid query:"
  puts query.errors
end
# puts "start: #{query.start_time}"
# puts "end:   #{query.end_time}"

conf.log_files.each do |log_file|
  if log_file.touched > query.start_time
    log_file.search(query)
  end    
end
