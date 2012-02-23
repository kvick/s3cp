# Copyright (C) 2010-2012 Alex Boisvert and Bizo Inc. / All rights reserved.
#
# Licensed to the Apache Software Foundation (ASF) under one or more contributor
# license agreements.  See the NOTICE file  distributed with this work for
# additional information regarding copyright ownership.  The ASF licenses this
# file to you under the Apache License, Version 2.0 (the "License"); you may not
# use this file except in compliance with the License.  You may obtain a copy of
# the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations under
# the License.

require 'rubygems'
require 'extensions/kernel' if RUBY_VERSION =~ /1.8/
require 'right_aws'
require 'optparse'
require 'date'
require 'highline/import'
require 'fileutils'
require 'digest'
require 'progressbar'

require 's3cp/utils'

# Parse arguments
options = {}
options[:verbose] = $stdout.isatty ? true : false
options[:headers] = []
options[:overwrite]   = ENV["S3CP_RETRIES"]     ? (ENV["S3CP_OVERWRITE"] =~ /y|yes|true|1|^\s*$/i ? true : false) : true
options[:checksum]    = ENV["S3CP_CHECKSUM"]    ? (ENV["S3CP_CHECKSUM"]  =~ /y|yes|true|1|^\s*$/i ? true : false) : true
options[:retries]     = ENV["S3CP_RETRIES"]     ? ENV["S3CP_RETRIES"].to_i     : 5
options[:retry_delay] = ENV["S3CP_RETRY_DELAY"] ? ENV["S3CP_RETRY_DELAY"].to_i : 1

op = OptionParser.new do |opts|
  opts.banner = <<-BANNER
    s3cp supports 4 copying use cases:
      1. Copy from local machine to S3
      2. Copy from S3 to local machine
      3. Copy from S3 to S3
      4. Copy from local machine to another path on local machine (for completeness)

    Local to S3:
      s3cp LOCAL_PATH S3_PATH

    S3 to Local:
      s3cp S3_PATH LOCAL_PATH

    S3 to S3:
      s3cp S3_PATH S3_PATH2

    Local to Local:
      s3cp LOCAL_PATH LOCAL_PATH2

  BANNER
  opts.separator ''

  opts.on("-r", "--recursive", "Recursive mode") do
    options[:recursive] = true
  end

  opts.on("--no-overwrite", "Does not overwrite existing files") do
    options[:overwrite] = false
  end

  opts.on("--max-attempts N", "Number of attempts to upload/download until checksum matches (default #{options[:retries]})") do |attempts|
    options[:retries] = attempts.to_i
  end

  opts.on("--retry-delay SECONDS", "Time to wait (in seconds) between retries (default #{options[:retry_delay]})") do |delay|
    options[:retry_delay] = delay.to_i
  end

  opts.on("--no-checksum", "Disable checksum checking") do
    options[:checksum] = false
  end

  opts.separator ""

  opts.on('--headers \'Header1: Header1Value\',\'Header2: Header2Value\'', Array, "Headers to set on the item in S3." ) do |h|
    options[:headers] = h
  end

  opts.separator "        e.g.,"
  opts.separator "              HTTP headers: \'Content-Type: image/jpg\'"
  opts.separator "               AMZ headers: \'x-amz-acl: public-read\'"
  opts.separator ""

  opts.on("--verbose", "Verbose mode") do
    options[:verbose] = true
  end

  opts.on("--debug", "Debug mode") do
    options[:debug] = true
  end

  opts.on_tail("-h", "--help", "Show this message") do
    puts op
    exit
  end
end
op.parse!(ARGV)

if ARGV.size < 2
  puts op
  exit
end

destination = ARGV.last
sources = ARGV[0..-2]

class Proxy
  instance_methods.each { |m| undef_method m unless m =~ /(^__|^send$|^object_id$)/ }

  def initialize(target)
    @target = target
  end

  protected

  def method_missing(name, *args, &block)
    #puts "method_missing! #{name} #{args.inspect}"
    @target.send(name, *args, &block)
  end
end

def s3?(url)
  S3CP.bucket_and_key(url)[0]
end

if options[:debug]
  puts "URL: #{url}"
  puts "Options: \n#{options.inspect}"
end

if options[:verbose]
  @verbose = true
end

@bucket = $1
@prefix = $2

@s3 = S3CP.connect()

def direction(from, to)
  if s3?(from) && s3?(to)
    :s3_to_s3
  elsif !s3?(from) && s3?(to)
    :local_to_s3
  elsif s3?(from) && !s3?(to)
    :s3_to_local
  else
    :local_to_local
  end
end

def no_slash(path)
  path = path.match(/\/$/) ? path[0..-2] : path
  path.match(/^\//) ? path[1..-1] : path
end

def relative(base, path)
  no_slash(path[base.length..-1])
end

def log(msg)
  puts msg if @verbose
end

def headers_array_to_hash(header_array)
  headers = {}
  header_array.each do |header|
    header_parts = header.split(": ", 2)
    if header_parts.size == 2
      headers[header_parts[0].downcase] = header_parts[1]  # RightAWS gem expect lowercase header names :(
    else
      log("Header ignored because of error splitting [#{header}].  Expected colon delimiter; e.g. Header: Value")
    end
  end
  headers
end
@headers = headers_array_to_hash(options[:headers])

def with_headers(msg)
  unless @headers.empty?
    msg += " with headers:"
    msg += @headers.collect{|k,v| "'#{k}: #{v}'"}.join(", ")
  end
  msg
end

def md5(filename)
  digest = Digest::MD5.new()
  file = File.open(filename, 'r')
  begin
    file.each_line do |line|
      digest << line
    end
  ensure
    file.close()
  end
  digest.hexdigest
end

def s3_to_s3(bucket_from, key, bucket_to, dest)
  log(with_headers("Copy s3://#{bucket_from}/#{key} to s3://#{bucket_to}/#{dest}"))
  if @headers.empty?
    @s3.interface.copy(bucket_from, key, bucket_to, dest)
  else
    @s3.interface.copy(bucket_from, key, bucket_to, dest, :copy, @headers)
  end
end

def local_to_s3(bucket_to, key, file, options = {})
  log(with_headers("Copy #{file} to s3://#{bucket_to}/#{key}"))
  if options[:checksum]
    expected_md5 = md5(file)
  end
  retries = 0
  begin
    if retries == options[:retries]
      fail "Unable to upload to s3://#{bucket_to}/#{key} after #{retries} attempts."
    end
    if retries > 0
      STDERR.puts "Warning: failed checksum for s3://#{bucket_to}/#{bucket_to}. Retrying #{options[:retries] - retries} more time(s)."
      sleep options[:retry_delay]
    end

    f = File.open(file)
    begin
      if $stdout.isatty
        f = Proxy.new(f)
        progress_bar = ProgressBar.new(File.basename(file), File.size(file)).tap do |p|
          p.file_transfer_mode
        end
        class << f
         attr_accessor :progress_bar
          def read(length, buffer=nil)
            begin
              result = @target.read(length, buffer)
              @progress_bar.inc result.length if result
              result
            rescue => e
              puts e
              raise e
            end
          end
        end
        f.progress_bar = progress_bar
      else
        progress_bar = nil
      end

      meta = @s3.interface.put(bucket_to, key, f, @headers)
      progress_bar.finish if progress_bar

      if options[:checksum]
        metadata = @s3.interface.head(bucket_to, key)
        actual_md5 = metadata["etag"] or fail "Unable to get etag/md5 for #{bucket_to}:#{key}"
        actual_md5 = actual_md5.sub(/^"/, "").sub(/"$/, "") # strip beginning and trailing quotes
        if actual_md5 =~ /-/
          STDERR.puts "Warning: invalid MD5 checksum in metadata; skipped checksum verification."
          actual_md5 = nil
        end
      end
    rescue => e
      raise e unless options[:checksum]
      STDERR.puts e
    ensure
      f.close()
    end
    retries += 1
    end until options[:checksum] == false || actual_md5.nil? || expected_md5 == actual_md5
end

def s3_to_local(bucket_from, key_from, dest, options = {})
  log("Copy s3://#{bucket_from}/#{key_from} to #{dest}")
  retries = 0
  begin
    if retries == options[:retries]
      File.delete(dest) if File.exist?(dest)
      fail "Unable to download s3://#{bucket_from}/#{key_from} after #{retries} attempts."
    end
    if retries > 0
      STDERR.puts "Warning: failed checksum for s3://#{bucket_from}/#{key_from}. Retrying #{options[:retries] - retries} more time(s)."
      sleep options[:retry_delay]
    end

    f = File.new(dest, "wb")
    begin
      size = nil
      if options[:checksum]
        metadata = @s3.interface.head(bucket_from, key_from)
        expected_md5 = metadata["etag"] or fail "Unable to get etag/md5 for #{bucket_from}:#{key_from}"
        expected_md5 = expected_md5.sub(/^"/, "").sub(/"$/, "") # strip beginning and trailing quotes
        if expected_md5 =~ /-/
          STDERR.puts "Warning: invalid MD5 checksum in metadata; skipped checksum verification."
          expected_md5 = nil
        end
        size = metadata["content-length"].to_i
      elsif $stdout.isatty
        metadata = @s3.interface.head(bucket_from, key_from)
        size = metadata["content-length"].to_i
      end
      begin
        progress_bar = if size
          ProgressBar.new(File.basename(key_from), size).tap do |p|
            p.file_transfer_mode
          end
        end
        @s3.interface.get(bucket_from, key_from) do |chunk|
          f.write(chunk)
          progress_bar.inc chunk.size if progress_bar
        end
        progress_bar.finish
      rescue => e
        progress_bar.halt if progress_bar
        raise e
      end
    rescue => e
      raise e unless options[:checksum]
      STDERR.puts e
    ensure
      f.close()
    end
    retries += 1
  end until options[:checksum] == false || expected_md5.nil? || md5(dest) == expected_md5
end

def s3_exist?(bucket, key)
  metadata = @s3.interface.head(bucket, key)
  #puts "exist? #{bucket} #{key} => #{metadata != nil}"
  (metadata != nil)
end

def copy(from, to, options)
  bucket_from, key_from = S3CP.bucket_and_key(from)
  bucket_to, key_to = S3CP.bucket_and_key(to)

  #puts "bucket_from #{bucket_from.inspect} key_from #{key_from.inspect}"
  #puts "bucket_to #{bucket_to.inspect} key_from #{key_to.inspect}"
  #puts "direction #{direction(from, to)}"

  case direction(from, to)
  when :s3_to_s3
    if options[:recursive]
      keys = []
      @s3.interface.incrementally_list_bucket(bucket_from, :prefix => key_from) do |page|
        page[:contents].each { |entry| keys << entry[:key] }
      end
      keys.each do |key|
        dest = no_slash(key_to) + '/' + relative(key_from, key)
        s3_to_s3(bucket_from, key, bucket_to, dest) unless !options[:overwrite] && s3_exist?(bucket_to, dest)
      end
    else
      s3_to_s3(bucket_from, key_from, bucket_to, key_to) unless !options[:overwrite] && s3_exist?(bucket_to, key_to)
    end
  when :local_to_s3
    if options[:recursive]
      files = Dir[from + "/**/*"]
      files.each do |f|
        f = File.expand_path(f)
        key = no_slash(key_to) + '/' + relative(from, f)
        local_to_s3(bucket_to, key, f, options) unless !options[:overwrite] && s3_exist?(bucket_to, key)
      end
    else
      local_to_s3(bucket_to, key_to, File.expand_path(from), options) unless !options[:overwrite] && s3_exist?(bucket_to, key_to)
    end
  when :s3_to_local
    if options[:recursive]
      keys = []
      @s3.interface.incrementally_list_bucket(bucket_from, :prefix => key_from) do |page|
        page[:contents].each { |entry| keys << entry[:key] }
      end
      keys.each do |key|
        dest = File.expand_path(to) + '/' + relative(key_from, key)
        dest = File.join(dest, File.basename(key)) if File.directory?(dest)
        dir = File.dirname(dest)
        FileUtils.mkdir_p dir unless File.exist? dir
        fail "Destination path is not a directory: #{dir}" unless File.directory?(dir)
        s3_to_local(bucket_from, key, dest, options) unless !options[:overwrite] && File.exist?(dest)
      end
    else
      dest = File.expand_path(to)
      dest = File.join(dest, File.basename(key_from)) if File.directory?(dest)
      s3_to_local(bucket_from, key_from, dest, options) unless !options[:overwrite] && File.exist?(dest)
    end
  when :local_to_local
    if options[:recursive]
      FileUtils.cp_r from, to
    else
      FileUtils.cp from, to
    end
  end
end

sources.each do |source|
  copy(source, destination, options)
end

