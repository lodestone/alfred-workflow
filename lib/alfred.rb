require 'rubygems' unless defined? Gem # rubygems is only needed in 1.8

require 'plist'
require 'fileutils'
require 'yaml'
require 'optparse'
require 'ostruct'
require 'gyoku'
require 'nori'

require 'alfred/ui'
require 'alfred/feedback'
require 'alfred/setting'
require 'alfred/handler/help'

module Alfred

  class AlfredError < RuntimeError
    def self.status_code(code)
      define_method(:status_code) { code }
    end
  end

  class ObjCError           < AlfredError; status_code(1) ; end
  class NoBundleIDError     < AlfredError; status_code(2) ; end
  class InvalidArgument     < AlfredError; status_code(10) ; end
  class InvalidFormat       < AlfredError; status_code(11) ; end
  class NoMethodError       < AlfredError; status_code(13) ; end
  class PathError           < AlfredError; status_code(14) ; end

  class << self

    #
    # Default entry point to build alfred workflow with this gem
    #
    # Example:
    #
    #    class MyHandler < ::Alfred::Handler::Base
    #      # ......
    #    end
    #    Alfred.with_friendly_error do |alfred|
    #      alfred.with_rescue_feedback = true
    #      alfred.with_help_feedback = true
    #      MyHandler.new(alfred).register
    #    end
    #
    def with_friendly_error(alfred = Alfred::Core.new, &blk)
      begin

        yield alfred
        alfred.start_handler

      rescue AlfredError => e
        alfred.ui.error e.message
        alfred.ui.debug e.backtrace.join("\n")
        puts alfred.rescue_feedback(
          :title => "#{e.class}: #{e.message}") if alfred.with_rescue_feedback
        exit e.status_code
      rescue Interrupt => e
        alfred.ui.error "\nQuitting..."
        alfred.ui.debug e.backtrace.join("\n")
        puts alfred.rescue_feedback(
          :title => "Interrupt: #{e.message}") if alfred.with_rescue_feedback
        exit 1
      rescue SystemExit => e
        puts alfred.rescue_feedback(
          :title => "SystemExit: #{e.status}") if alfred.with_rescue_feedback
        alfred.ui.error e.message
        alfred.ui.debug e.backtrace.join("\n")
        exit e.status
      rescue Exception => e
        alfred.ui.error(
          "A fatal error has occurred. " \
          "You may seek help in the Alfred supporting site, "\
          "forum or raise an issue in the bug tracking site.\n" \
          "  #{e.inspect}\n  #{e.backtrace.join("  \n")}\n")
        puts alfred.rescue_feedback(
          :title => "Fatal Error!") if alfred.with_rescue_feedback
        exit(-1)
      end
    end

    def workflow_folder
      Dir.pwd
    end

    # launch alfred with query
    def search(query = "")
      %x{osascript <<__APPLESCRIPT__
      tell application "Alfred 2"
        search "#{query.gsub('"','\"')}"
      end tell
__APPLESCRIPT__}
    end

    def front_appname
      %x{osascript <<__APPLESCRIPT__
      name of application (path to frontmost application as text)
__APPLESCRIPT__}.chop
    end

    def front_appid
      %x{osascript <<__APPLESCRIPT__
      id of application (path to frontmost application as text)
__APPLESCRIPT__}.chop
    end

  end

  class Core
    attr_accessor :with_rescue_feedback, :with_help_feedback
    attr_accessor :cached_feedback_reload_option

    attr_reader :handler_controller
    attr_reader :query, :raw_query


    def initialize(&blk)
      @with_rescue_feedback = true
      @with_help_feedback = false
      @cached_feedback_reload_option = {
        :use_reload_option => false,
        :use_exclamation_mark => false
      }

      @raw_query = ARGV.dup

      @handler_controller = ::Alfred::Handler::Controller.new

      instance_eval(&blk) if block_given?
    end


    def debug?
      ui.level >= LogUI::WARN
    end

    #
    # Main loop to work with handlers
    #
    def start_handler

      if @with_help_feedback
        ::Alfred::Handler::Help.new(self, :with_handler_help => true).register
      end

      return if @handler_controller.empty?

      # step 1: register option parser for handlers
      @handler_controller.each do |handler|
        handler.on_parser
      end

      begin
        query_parser.parse!
      rescue OptionParser::InvalidOption, OptionParser::MissingArgument => e
        ui.warn(
          "Fail to parse user query.\n" \
          "  #{e.inspect}\n  #{e.backtrace.join("  \n")}\n") if debug?
      end

      if @cached_feedback_reload_option[:use_exclamation_mark] && !options.should_reload_cached_feedback
        if ARGV[0].eql?('!')
          ARGV.shift
          options.should_reload_cached_feedback = true
        elsif ARGV[-1].eql?('!')
          ARGV.delete_at(-1)
          options.should_reload_cached_feedback = true
        end
      end

      @query = ARGV

      # step 2: dispatch options to handler for FEEDBACK or ACTION
      case options.workflow_mode
      when :feedback
        @handler_controller.each_handler do |handler|
          handler.on_feedback
        end

        puts feedback.to_alfred(@query)
      when :action
        arg = @query
        if @query.length == 1
          if hsh = xml_parser(@query[0])
            arg = hsh
          end
        end

        if arg.is_a?(Hash)
          @handler_controller.each_handler do |handler|
            handler.on_action(arg)
          end
        else
          #fallback default action
          arg.each do |a|
            if File.exist? a
              %x{open "#{a}"}
            end
          end
        end
      else
        raise InvalidArgument, "#{options.workflow_mode} mode is not supported."
      end

      # step 3: close
      @feedback.close if @feedback
      @handler_controller.each_handler do |handler|
        handler.on_close
      end

    end

    #
    # Parse and return user query to three parts
    #
    #   [ [before], last option, tail ]
    #
    def last_option
      (@raw_query.size - 1).downto(0) do |i|
        if @raw_query[i].start_with? '-'
          if @raw_query[i] == @raw_query[-1]
            return @raw_query[0...i], '', @raw_query[i]
          else
            return @raw_query[0..i], @raw_query[i], @raw_query[(i + 1)..-1].join(' ')
          end
        end
      end

      return [], '', @raw_query.join(' ')
    end

    def options(opts = {})
      @options ||= OpenStruct.new(opts)
    end

    def query_parser
      @query_parser ||= init_query_parser
    end

    def xml_parser(xml)
      @xml_parser ||= Nori.new(:parser => :rexml,
                               :convert_tags_to => lambda { |tag| tag.to_sym })
      begin
        hsh = @xml_parser.parse(xml)
        return hsh[:root]
      rescue REXML::ParseException, Nokogiri::XML::SyntaxError
        return nil
      end
    end

    def xml_builder(arg)
      Gyoku.xml(:root => arg)
    end

    def ui
      raise NoBundleIDError unless bundle_id
      @ui ||= LogUI.new(bundle_id)
    end

    def setting(&blk)
      @setting ||= Setting.new(self, &blk)
    end

    alias_method :user_setting, :setting

    def workflow_setting(opts = {})
      @workflow_setting ||= init_workflow_setting(opts)
    end

    def feedback(&blk)
      raise NoBundleIDError unless bundle_id
      @feedback ||= Feedback.new(self, &blk)
    end

    alias_method :with_cached_feedback, :feedback

    def info_plist
      @info_plist ||= Plist::parse_xml('info.plist')
    end

    # Returns nil if not set.
    def bundle_id
      @bundle_id ||= info_plist['bundleid'] unless info_plist['bundleid'].empty?
    end

    def volatile_storage_path
      raise NoBundleIDError unless bundle_id
      path = "#{ENV['HOME']}/Library/Caches/com.runningwithcrayons.Alfred-2/Workflow Data/#{bundle_id}"
      unless File.exist?(path)
        FileUtils.mkdir_p(path)
      end
      path
    end

    # Non-volatile storage directory for this bundle
    def storage_path
      raise NoBundleIDError unless bundle_id
      path = "#{ENV['HOME']}/Library/Application Support/Alfred 2/Workflow Data/#{bundle_id}"
      unless File.exist?(path)
        FileUtils.mkdir_p(path)
      end
      path
    end


    def cached_feedback?
      @cached_feedback_reload_option.values.any?
    end


    def rescue_feedback(opts = {})
      default_opts = {
        :title        => "Failed Query!"                                  ,
        :subtitle     => "Check log #{ui.log_file} for extra debug info." ,
        :uid          => 'Rescue Feedback'                                ,
        :valid        => 'no'                                             ,
        :autocomplete => ''                                               ,
        :icon         => Feedback.CoreServicesIcon('AlertStopIcon')
      }
      if @with_help_feedback
       default_opts[:autocomplete] = '-h'
      end
      opts = default_opts.update(opts)

      items = []
      items << Feedback::Item.new(opts[:title], opts)
      log_item = Feedback::FileItem.new(ui.log_file)
      log_item.uid = nil
      items << log_item

      feedback.to_alfred('', items)
    end

    def on_help
      reload_help_item
    end


    private

    def init_workflow_setting(opts)
      default_opts = {
        :file    => File.join(Alfred.workflow_folder, "setting.yaml"),
        :format  => 'yaml',
      }
      opts = default_opts.update(opts)

      Setting.new(self) do
        @backend_file = opts[:file]
        @formt = opts[:format]
      end
    end

    def reload_help_item
      title = []
      if  @cached_feedback_reload_option[:use_exclamation_mark]
        title.push "!"
      end

      if @cached_feedback_reload_option[:use_reload_option]
        title.push "-r, --reload"
      end

      unless title.empty?
        return {
          :kind  => 'text',
          :order => 100,
          :title => "#{title.join(', ')} [Reload cached feedback unconditionally]" ,
          :subtitle => %q{The '!' mark must be at the beginning or end of the query.} ,
        }
      else
        return nil
      end
    end

    def init_query_parser
      options.workflow_mode = :feedback
      options.modifier = :none
      options.should_reload_cached_feedback = false

      modifiers = [:command, :alt, :control, :shift, :fn, :none]
      OptionParser.new do |opts|
        opts.separator ""
        opts.separator "Built-in Options:"

        opts.on("--workflow-mode [TYPE]", [:feedback, :action],
                "Alfred handler working mode (feedback, action)") do |t|
          options.workflow_mode = t
        end

        opts.on("--modifier [MODIFIER]", modifiers,
                "Alfred action modifier (#{modifiers})") do |t|
          options.modifier = t
        end

        if @cached_feedback_reload_option[:use_reload_option]
          opts.on("-r", "--reload", "Reload cached feedback") do
            options.should_reload_cached_feedback = true
          end
        end
        opts.separator ""
        opts.separator "Handler Options:"
      end

    end
  end
end

