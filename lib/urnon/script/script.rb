require "benchmark"
require 'urnon/session'
require "urnon/util/limited-array"
require "urnon/util/format"
require "urnon/ext/thread"
require 'urnon/script/runtime'
require 'urnon/script/opts'

GLOBAL_SCRIPT_CONTEXT = binding()

class Script < Thread
  class Shutdown < StandardError; end;
  # internal script status codes
  class Status
    Err    = :err
    Ok     = :ok
    Killed = :killed
  end
  # global scripting lock
  GLOBAL_SCRIPT_LOCK ||= Mutex.new
  @@running          ||= Array.new
  @@lock_holder      ||= nil

  Script.abort_on_exception  = false
  Script.report_on_exception = false

  def self.running(); @@running.dup; end
  def self.list(); Script.running(); end
  def self.hidden(); running.select(&:hidden?); end
  def self.atomic(); GLOBAL_SCRIPT_LOCK.synchronize {yield}; end

  def self.namescript_incoming(line)
    Script.new_downstream(line)
  end

  def self._current()
    # fastest lookup possible
    return Thread.current if Thread.current.is_a?(Script)
    # second fastest lookup possible
    return Thread.current.parent if Thread.current.parent.is_a?(Script)
    # prefer current thread
    script = running.find {|script| script.eql?(Thread.current) }
    # else check if was launched by a script
    script = running.find {|script| script.eql?(Thread.current.parent) } if script.nil?
  end

  def self.current()
    script = _current
    return nil if script.nil?
    sleep 0.1 while script.paused?
    return script unless block_given?
    yield script
  end

  def self.self(); current(); end

  def self.script_name(file_name)
     file_name.slice(SCRIPT_DIR.size+1..-(File.extname(file_name).size + 1))
  end

  def self.running?(name)
     @@running.any? { |i| (i.name =~ /^#{name}$/i) }
  end

  def self.pause(name=nil)
    if name.nil?
      Script.current.pause
      return Script.current
    end

    if s = @@running.reject(&:paused?).find { |i| i.name.downcase == name.downcase}
      s.pause
      return s
    end
  end

  def self.unpause(name)
    if s = @@running.select(&:paused?).find { |i| i.name.downcase == name.downcase}
      s.unpause
      return s
    end
  end

  def self.kill(name)
    return name.halt if name.is_a?(Script)
    if s = @@running.find { |i| i.name.downcase == name.downcase }
      s.halt
      sleep 0.1 while s.status.is_a?(String)
    end
  end

  def self.paused?(name)
    if s = @@running.select(&:paused?).find { |i| i.name.downcase == name.downcase}
      return s.paused?
    end

    return nil
  end

  def self.glob()
    File.join(SCRIPT_DIR, "**", "*.{lic,rb}")
  end

  def self.match(script_name)
    script_name = script_name.downcase
    pattern = if script_name.include?(".")
    then Regexp.new(Regexp.escape(script_name) + "$")
    else Regexp.new("%s.*\.(lic|rb)$" % Regexp.escape(script_name))
    end
    Dir.glob(Script.glob)
      .select {|file|
        File.file?(file) && file =~ pattern
      }
      .sort_by {|file|
          file.index("#{script_name}.lic") ||
          file.index("#{script_name}.rb") ||
          file.size
      }
  end

  def self.exist?(script_name)
    match(script_name).size.eql?(1)
  end

  # this is not the way, ruby standards say it should be `exist?`
  def self.exists?(script_name)
    exist?(script_name)
  end

  def self.new_downstream_xml(line)
    for script in @@running
      script.downstream_buffer.push(line.chomp) if script.want_downstream_xml
    end
  end

  def self.new_upstream(line)
     for script in @@running
        script.upstream_buffer.push(line.chomp) if script.want_upstream
     end
  end

  def self.new_downstream(line)
     @@running.each { |script|
        script.downstream_buffer.push(line.chomp) if script.want_downstream
        unless script.watchfor.empty?
          script.watchfor.each_pair { |trigger,action|
            if line =~ trigger
              new_thread = Thread.new {
                sleep 0.011 until Script.current
                begin
                    action.call
                rescue => e
                    print_error(e)
                end
              }
              script.thread_group.add(new_thread)
            end
          }
        end
     }
  end

  def self.new_script_output(line)
     for script in @@running
        script.downstream_buffer.push(line.chomp) if script.want_script_output
     end
  end

  def self.log(data)
     script = Script.current
     begin
        Dir.mkdir("#{LICH_DIR}/logs") unless File.exists?("#{LICH_DIR}/logs")
        File.open("#{LICH_DIR}/logs/#{script.name}.log", 'a') { |f| f.puts data }
        true
     rescue => e
        print_error(e)
        false
     end
  end

  def self.open_file(*args)
    fail Exception, "Script.open_file() is deprecated\nuse File.open from the ruby stdlib"
  end

  def self.at_exit(&block)
     Script.current do |script|
        script.at_exit(&block)
     end
  end

  def self.clear_exit_procs
     if script = Script.current
        script.clear_exit_procs
     else
        respond "--- urnon: error: Script.clear_exit_procs: can't identify calling script"
        return false
     end
  end

  def self.exit!
     if script = Script.current
        script.exit!
     else
        respond "--- urnon: error: Script.exit!: can't identify calling script"
        return false
     end
  end

  def self.find(name)
    Script.list.find {|script| script.name.include?(name)}
  end

  def self.start(*args, session: nil)
    Script.of(args, session: session)
  end

  def self.run(*args, session: nil)
    s = Script.of(args, session: session)
    return s unless s.is_a?(Script)
    s.value
    return s
  end

  def self.runtime(session)
    session.sandbox
  end

  def self.of(args, session: nil)
    opts = {}

    # inherit if not explicitly passed
    session = Script.current.session if session.nil? && Script.current && Script.current.session.is_a?(Session)

    (name, scriptv, kwargs) = args
    opts.merge!(kwargs) if kwargs.is_a?(Hash)
    opts[:name] = name
    opts[:file] = Script.match(opts[:name]).first
    opts[:args] = scriptv
    opts[:session] = session

    raise ArgumentError, "could not start Script(%s) without a Session" % opts[:name] if session.nil?

    opts.merge!(scriptv) if scriptv.is_a?(Hash)

    if opts[:file].nil?
      session.to_client "--- urnon: could not find script #{opts[:name]} not found in #{Script.glob}"
      return :not_found
    end

    opts[:name] = Script.script_name opts[:file]

    if Script.running.find { |s| s.name.eql?(opts[:name]) && s.session.eql?(session) } and not opts[:force]
      session.to_client "--- urnon: #{opts[:name]} is already running"
      return :already_running
    end

    Script.new(opts) { |script, runtime|
      runtime = Script.runtime(script.session)
      runtime.local_variable_set :script, script
      runtime.instance_eval(script.contents, script.file_name)
    }
  end

  attr_reader :name, :vars, :safe,
              :file_name, :at_exit_procs,
              :thread_group, :_value, :shutdown,
              :start_time, :run_time,
              :session

  attr_accessor :quiet, :no_echo, :paused,
                :hidden, :silent,
                :want_downstream, :want_downstream_xml,
                :want_upstream, :want_script_output,
                :no_pause_all, :no_kill_all,
                :downstream_buffer, :upstream_buffer, :unique_buffer,
                :die_with, :watchfor, :command_line, :ignore_pause,
                :_value, :exit_status, :opts

  def initialize(args, &block)
    @file_name = args[:file]
    @name = args[:name]
    @session = args[:session]
    @vars = case args[:args]
      when Array
        args[:args]
      when String
        if args[:args].empty?
          []
        else
          [args[:args]].concat(args[:args]
            .scan(/[^\s"]*(?<!\\)"(?:\\"|[^"])+(?<!\\)"[^\s]*|(?:\\"|[^"\s])+/)
            .collect { |s| s.gsub(/(?<!\\)"/,'')
            .gsub('\\"', '"') })
        end
      else
        []
      end
    @opts  = Opts.parse(@vars)
    @quiet = args.fetch(:quiet, false)
    @downstream_buffer = LimitedArray.new
    @want_downstream = true
    @want_downstream_xml = false
    @want_script_output = false
    @upstream_buffer = LimitedArray.new
    @want_upstream = false
    @unique_buffer = LimitedArray.new
    @watchfor = Hash.new
    @_value = :unknown
    @at_exit_procs = []
    @die_with = []
    @hidden = false
    @no_pause_all = false
    @no_kill_all = false
    @silent = false
    @shutdown = false
    @paused = false
    @no_echo = false
    @thread_group = ThreadGroup.new
    @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @exit_status = nil
    @@running.push(self)
    @thread_group.add(self)
    super {
      self.priority = 1
      Thread.handle_interrupt(Script::Shutdown => :never) do
        script = self
        begin
          Thread.handle_interrupt(Script::Shutdown => :immediate) do
            respond("--- urnon: #{script.name} active.") unless script.quiet
            begin
              script._value = yield(script, self)
            rescue Shutdown => e
              script.exit_status = Status::Killed
            rescue Exception => e
              script.print_error(e)
              script.exit_status = Status::Err
            else
              script.exit_status = Status::Ok if script.exit_status.nil?
            end
          end
        ensure
          script.exit_status = Status::Killed unless script.exit_status
          script._value = nil if script._value.eql?(:unknown)
          script.before_shutdown()
          respond("--- urnon: #{script.name} exiting with status: #{script.exit_status} in #{script.uptime}")
          script.halt()
        end
      end
    }
  end

  def print_error(e)
    self.session.to_client "script:%s:error: %s" % [self.name, e.message]
    self.session.to_client "script:%s:backtrace:\n%s" % [self.name, e.backtrace.join("\n")]
  end

  def uptime()
    Format.time(Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
  end

  def before_shutdown()
    begin
      @shutdown = true
      at_exit_procs.each(&:call)
      # ensure sub-scripts are kills
      @die_with.each { |script_name| Script.unsafe_kill(script_name) }
      # all Thread created by this script
      resources = @thread_group.list + self.child_threads
      resources.each {|child|
        unless child.is_a?(Script)
          child.dispose
          Thread.kill(child)
        end
      }
    rescue StandardError => e
      print_error(e)
    end
    self
  end

  def value()
    return @_value unless @_value.eql?(:unknown)
    super
  end

  def db()
    SQLite3::Database.new("#{DATA_DIR}/#{script.name.gsub(/\/|\\/, '_')}.db3")
  end

  def contents()
    File.read(self.file_name)
  end

  def hidden?
     @hidden
  end

  def inspect
    "%s<%s status=%s uptime=%s value=%s>" % [
      self.name, @name,
        self.status, uptime, @_value.inspect]
  end

  def status()
    return super if alive?
    return @exit_status
  end

  def script()
    # todo: deprecate this
    self
  end

  def halt()
    return if @_halting
    @_halting = true
    begin
      @exit_status = Status::Killed unless @exit_status
      if self.alive?
        self.raise(Script::Shutdown)
        self.join(10) rescue nil
        @_value = :shutdown if @_value.eql?(:unknown)
      end
    ensure
      @@running.delete(self)
      self.dispose()
      self.kill()
      self
    end
  end


  def at_exit(&block)
    return @at_exit_procs << block if block_given?
    respond '--- warning: Script.at_exit called with no code block'
  end

  def clear_exit_procs
    @at_exit_procs.clear
    true
  end

  def exit(status = 0)
    @exit_status = status
    self.halt
  end

  def exit!
    @at_exit_procs.clear
    self.exit(:sigkill)
  end

  def has_thread?(t)
    @thread_group.list.include?(t)
  end

  def pause
    respond "--- urnon: #{@name} paused."
    @paused = true
  end

  def unpause
    respond "--- urnon: #{@name} unpaused."
    @paused = false
  end

  def paused?
    @paused == true
  end

  def clear
    to_return = @downstream_buffer.dup
    @downstream_buffer.clear
    to_return
  end

  def gets
    # fixme: no xml gets
    if @want_downstream or @want_downstream_xml or @want_script_output
      sleep 0.05 while @downstream_buffer.empty?
      @downstream_buffer.shift
    else
      echo 'this script is set as unique but is waiting for game data...'
      sleep 2
      false
    end
  end

  def gets?
     if @want_downstream or @want_downstream_xml or @want_script_output
        if @downstream_buffer.empty?
           nil
        else
           @downstream_buffer.shift
        end
     else
        echo 'this script is set as unique but is waiting for game data...'
        sleep 2
        false
     end
  end

  def upstream_gets
    sleep 0.05 while @upstream_buffer.empty?
    @upstream_buffer.shift
  end

  def upstream_gets?
    if @upstream_buffer.empty?
      nil
    else
      @upstream_buffer.shift
    end
  end

  def unique_gets
    sleep 0.05 while @unique_buffer.empty?
    @unique_buffer.shift
  end

  def unique_gets?
    if @unique_buffer.empty?
      nil
    else
      @unique_buffer.shift
    end
  end

  def feedme_upstream
    @want_upstream = !@want_upstream
  end
end
