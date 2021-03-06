#!/usr/bin/env ruby
#
# TUNGSTEN SCALE-OUT STACK
# Copyright (C) 2011 Continuent, Inc.
# All rights reserved
#

# System libraries.
require 'tungsten/system_require'

system_require 'optparse'
system_require 'ostruct'
system_require 'date'
system_require 'fileutils'
system_require 'socket'

# Tungsten local libraries.
require 'tungsten/parameter_names'
require 'tungsten/properties'
require 'tungsten/transformer'


# Manages top-level configuration.
class ServiceConfigurator
  attr_reader :options, :config

  # Global parameter names
  include ParameterNames

  CREATE = "create"
  DELETE = "delete"
  UPDATE = "update"

  # Local service parameters. 
  REPL_SVC_ALLOW_ANY_SERVICE = "repl_svc_allow_any_remote_service"
  REPL_SVC_ALLOW_BIDI_UNSAFE = "repl_svc_allow_bidi_unsafe"
  REPL_SVC_BINLOG_MODE = "repl_svc_binlog_mode"
  REPL_SVC_CHANNELS = "repl_svc_channels"
  REPL_SVC_ENFORCE_HOME = "repl_svc_enforce_home"
  REPL_SVC_EXTRACT_DB_HOST = "repl_svc_extract_db_host"
  REPL_SVC_EXTRACT_DB_PASSWORD = "repl_svc_extract_db_password"
  REPL_SVC_EXTRACT_DB_PORT = "repl_svc_extract_db_port"
  REPL_SVC_EXTRACT_DB_USER = "repl_svc_extract_db_user"
  REPL_SVC_MASTERPORT = "repl_svc_masterport"
  REPL_SVC_NATIVE_SLAVE_TAKEOVER = "repl_svc_native_slave_takeover"
  REPL_SVC_PARALLELIZATION_TYPE = "repl_svc_parallelization_type"
  REPL_SVC_SERVICE_TYPE = "repl_svc_service_type"
  REPL_SVC_SHARD_DEFAULT_DB = "repl_svc_shard_default_db"
  REPL_SVC_THL_PORT = "repl_svc_thl_port"

  # Initialize configuration arguments.
  def initialize(arguments, stdin)
    # Set instance variables.
    @arguments = arguments
    @config = nil

    # Set command line argument defaults.
    @options = OpenStruct.new
    @options.help = false
    @options.verbose = false
    @options.operation = nil
    @options.config = "tungsten.cfg"
    @options.clear_dynamic = false

    @config_overrides = Properties.new
  end

  # Parse options, check arguments, then process the command
  def run
    write_header "Tungsten Replication Service Configuration"
    # Parse options.
    if ! parsed_options? 
      output_usage
      exit 1
    end
    output_options if @options.verbose # [Optional]

    if @options.help
      output_usage;
      exit 0
    end

    if ! arguments_valid?
      output_usage
      exit 1
    end

    # Load configuration file.
    if ! load_config
      return
    end

    # Execute operation.
    if @options.operation == CREATE
      exec_create
    elsif @options.operation == DELETE
      exec_delete
    elsif @options.operation == UPDATE
      exec_update
    else
      fatal "No service operation found: must specify -C, -D, or -U option"
    end
    puts "\nFinished at #{DateTime.now}" if @options.verbose
  end

  # Parse command line arguments.
  def parsed_options?
    opts=OptionParser.new
    # General options. 
    opts.on("-C", "--create")         {@options.operation = CREATE}
    opts.on("-D", "--delete")         {@options.operation = DELETE}
    opts.on("-U", "--update")         {@options.operation = UPDATE}
    opts.on("-c", "--config String")  {|val| @options.config = val }
    #opts.on("-f", "--force")         {@options.force = true}
    opts.on("--clear-dynamic")        {@options.clear_dynamic = true}
    opts.on("-h", "--help")           {@options.help = true}
    opts.on("-V", "--verbose")        {@options.verbose = true}

    # Service options. 
    opts.on("--auto-enable String") {|val| 
      @config_overrides.setProperty(REPL_AUTOENABLE, val)}
    opts.on("--binlog-mode String") {|val| 
      @config_overrides.setProperty(REPL_SVC_BINLOG_MODE, val)}
    opts.on("--buffer-size String")    {|val| 
      @config_overrides.setProperty(REPL_BUFFER_SIZE, val)}
    opts.on("--channels String")    {|val| 
      @config_overrides.setProperty(REPL_SVC_CHANNELS, val)}
    opts.on("--enforce-home String")    {|val| 
      @config_overrides.setProperty(REPL_SVC_ENFORCE_HOME, val)}
    opts.on("--local-service-name String")    {|val| 
      @config_overrides.setProperty(GLOBAL_DSNAME, val)}
    opts.on("--extract-db-host String")    {|val| 
      @config_overrides.setProperty(REPL_SVC_EXTRACT_DB_HOST, val)}
    opts.on("--extract-db-port String")    {|val| 
      @config_overrides.setProperty(REPL_SVC_EXTRACT_DB_PORT, val)}
    opts.on("--extract-db-user String")    {|val| 
      @config_overrides.setProperty(REPL_SVC_EXTRACT_DB_USER, val)}
    opts.on("--extract-db-password String")    {|val| 
      @config_overrides.setProperty(REPL_SVC_EXTRACT_DB_PASSWORD, val)}
    opts.on("--master-host String") {|val| 
      @config_overrides.setProperty(REPL_MASTERHOST, val)}
    opts.on("--master-port String") {|val| 
      @config_overrides.setProperty(REPL_SVC_MASTERPORT, val)}
    opts.on("--relay-log-dir String") {|val|
      @config_overrides.setProperty(REPL_RELAY_LOG_DIR, val)}
    opts.on("--role String")        {|val| 
      @config_overrides.setProperty(REPL_ROLE, val)}
    opts.on("--service-type String")        {|val| 
      @config_overrides.setProperty(REPL_SVC_SERVICE_TYPE, val)}
    opts.on("--thl-conn-timeout String") {|val|
      @config_overrides.setProperty(REPL_THL_LOG_CONNECTION_TIMEOUT, val) }
    opts.on("--thl-do-checksum String") {|val| 
      @config_overrides.setProperty(REPL_THL_DO_CHECKSUM, val) }
    opts.on("--thl-log-dir String") {|val|
      @config_overrides.setProperty(REPL_LOG_DIR, val) }
    opts.on("--thl-logfile-size String") {|val|
      @config_overrides.setProperty(REPL_THL_LOG_FILE_SIZE, val) }
    opts.on("--thl-port String") {|val|
      @config_overrides.setProperty(REPL_SVC_THL_PORT, val) }
    opts.on("--extract-method String") {|val|
      @config_overrides.setProperty(REPL_MYSQL_EXTRACT_METHOD, val)}
    opts.on("--shard-default-db String") {|val|
      @config_overrides.setProperty(REPL_SVC_SHARD_DEFAULT_DB, val)}
    opts.on("--parallelization-type String") {|val|
      @config_overrides.setProperty(REPL_SVC_PARALLELIZATION_TYPE, val)}
    opts.on("--native-slave-takeover String") {|val|
      @config_overrides.setProperty(REPL_SVC_NATIVE_SLAVE_TAKEOVER, val)}
    opts.on("--allow-bidi-unsafe String") {|val|
      @config_overrides.setProperty(REPL_SVC_ALLOW_BIDI_UNSAFE, val)}
    opts.on("--allow-any-remote-service String") {|val|
      @config_overrides.setProperty(REPL_SVC_ALLOW_ANY_SERVICE, val)}

    @options.remainder = opts.parse(@arguments) rescue
    begin
      puts "Argument parsing failed"
      return false
    end

    true
  end

  # True if required arguments were provided and are valid.
  def arguments_valid?
    # Options file must be readable.
    if ! @options.config
      puts "No config file specified"
      false
    elsif ! File.readable?(@options.config)
      puts "Config file does not exist or is not readable: #{@options.config}"
      false
    end

    # Ensure we have a service name. 
    if @options.remainder == "" 
      @options.service_name = nil
    else
      @options.service_name = @options.remainder[0]
    end

    true
  end

  def output_help
    output_version
    output_usage
  end

  def output_usage
    puts "Usage: configure-service {-C|-D|-U} [options] service-name"
    write_divider
    puts "General options:"
    puts "-C, --create       Create a new replication service"
    puts "-D, --delete       Delete an existing replication service"
    puts "-U, --update       Update an existing replication service"
    puts "-c, --config file  Sets name of config file (default: tungsten.cfg)"
    #puts "-f, --force        Do not prompt before executing operations"
    puts "-h, --help         Displays help message"
    puts "-V, --verbose      Verbose output"
    puts "--clear-dynamic    Clear dynamic properties on service update"
    write_divider
    puts "Service options:"

    # See if we can load configuration file. 
    cfg_loaded = load_config
    if cfg_loaded
      puts "(Defaults shown from config file: #{@options.config})"
    else
      puts "(Unable to load defaults from config file: #{@options.config})"
    end
    printf "--allow-bidi-unsafe   Allow unsafe SQL from remote service [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_ALLOW_BIDI_UNSAFE)
    printf "--allow-any-remote-service  Replicate from any service [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_ALLOW_ANY_SERVICE)
    printf "--auto-enable      If true, service goes online at startup [%s]\n", 
      output_param(cfg_loaded, REPL_AUTOENABLE)
    printf "--binlog-mode      Read MySQL binlog or slave relay log (master|slave-relay) [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_BINLOG_MODE)
    printf "--buffer-size      Size of buffers for block commit and queues [%s]\n", 
      output_param(cfg_loaded, REPL_BUFFER_SIZE)
    printf "--channels         Number of channels for parallel apply [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_CHANNELS)
    printf "--enforce-home     Enforce shard homes [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_ENFORCE_HOME)
    printf "--extract-db-host  Extractor DBMS host name [%s]\n", 
      output_param(cfg_loaded, REPL_DATASERVER_HOST)
    printf "--extract-db-password  Extractor DBMS password[%s]\n", 
      output_param(cfg_loaded, REPL_DBPASSWORD)
    printf "--extract-db-port  Extractor DBMS port number [%s]\n", 
      output_param(cfg_loaded, REPL_DBPORT)
    printf "--extract-db-user  Extractor DBMS user [%s]\n", 
      output_param(cfg_loaded, REPL_DBLOGIN)
    printf "--extract-method   Binlog extraction method (direct|relay) [%s]\n", 
      output_param(cfg_loaded, REPL_MYSQL_EXTRACT_METHOD)
    printf "--local-service-name  Replicator service that owns master [%s]\n", 
      output_param(cfg_loaded, GLOBAL_DSNAME)
    printf "--master-host      Replicator remote master host name [%s]\n", 
      output_param(cfg_loaded, REPL_MASTERHOST)
    printf "--master-port      Replicator remote master port [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_MASTERPORT)
    printf "--native-slave-takeover Replacing native slave replication [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_NATIVE_SLAVE_TAKEOVER)
    printf "--parallelization-type Parallelization method (disk|memory) [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_PARALLELIZATION_TYPE)
    printf "--relay-log-dir    Directory for relay log files [%s]\n", 
      output_param(cfg_loaded, REPL_RELAY_LOG_DIR)
    printf "--role             Replicator role [%s]\n", 
      output_param(cfg_loaded, REPL_ROLE)
    printf "--service-type     Replicator service type (local|remote) [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_SERVICE_TYPE)
    printf "--shard-default-db Use default db for shard ID (stringent|relaxed) [%s]\n",
      output_param(cfg_loaded, REPL_SVC_SHARD_DEFAULT_DB)
    printf "--thl-conn-timeout Idle timeout on internal THL connections [%s]\n", 
      output_param(cfg_loaded, REPL_THL_LOG_CONNECTION_TIMEOUT)
    printf "--thl-do-checksum  If true, checksum THL records [%s]\n", 
      output_param(cfg_loaded, REPL_THL_DO_CHECKSUM)
    printf "--thl-log-dir      Directory for THL log files [%s]\n", 
      output_param(cfg_loaded, REPL_LOG_DIR)
    printf "--thl-logfile-size Size in bytes of THL log files [%s]\n", 
      output_param(cfg_loaded, REPL_THL_LOG_FILE_SIZE)
    printf "--thl-port         THL server listener port [%s]\n", 
      output_param(cfg_loaded, REPL_SVC_THL_PORT)
  end

  def output_param(cfg_loaded, name)
    if cfg_loaded 
      @config.getProperty(name)
    else
      ""
    end
  end

  def output_version
    puts "#{File.basename(__FILE__)} version #{VERSION}"
  end

  # Load current configuration values.
  def load_config
    puts "Loading config file: #{@options.config}" if @options.verbose
    @config = Properties.new
    if ! File.exist?(@options.config)
      return false
    end

    @config.load_and_initialize(@options.config, ParameterNames)

    # Set local default values. 
    @config.setProperty(REPL_SVC_CHANNELS, "1")
    @config.setProperty(REPL_SVC_ENFORCE_HOME, "false")
    @config.setProperty(REPL_SVC_MASTERPORT, "2112")
    @config.setProperty(REPL_SVC_THL_PORT, "2112")
    @config.setProperty(REPL_SVC_BINLOG_MODE, "master")
    @config.setProperty(REPL_SVC_SHARD_DEFAULT_DB, "stringent")
    @config.setProperty(REPL_SVC_ALLOW_BIDI_UNSAFE, "false")
    @config.setProperty(REPL_SVC_ALLOW_ANY_SERVICE, "false")
    @config.setProperty(REPL_SVC_PARALLELIZATION_TYPE, "memory")
    @config.setProperty(REPL_SVC_NATIVE_SLAVE_TAKEOVER, "false")

    # Apply override values. 
    @config_overrides.hash().keys.each {|key| 
      @config.setProperty(key, @config_overrides.getProperty(key))
    }
 
    # Load is done. 
    true
  end

  # Execute service creation.
  def exec_create
    if ! @options.service_name 
      fatal "Service name is required for service creation"
    end    

    puts 
    puts "Creating new replication service: #{@options.service_name}" 
    write_divider

    # Create and validate the static and dynamic file names. 
    static_props = name_of_static_props()
    if File.exists?(static_props)
      fatal "Static properties file already exists: #{static_props}"
    end

    dynamic_props = name_of_dynamic_props()
    if File.exists?(dynamic_props)
      fatal "Dynamic properties file already exists: #{dynamic_props}"
    end

    # Get the log directory. 
    log_dir = name_of_log_dir()
    if File.exists?(log_dir)
      fatal "Service log directory already exists: #{log_dir}"
    end

    # Get the relay-log directory.  
    relay_log_dir = name_of_relay_log_dir()
    if File.exists?(relay_log_dir)
      fatal "Service relay log directory already exists: #{relay_log_dir}"
    end

    # Create required directories. 
    puts "Creating disk log directory: #{log_dir}"
    Dir.mkdir(log_dir)
    
    if @config.props[REPL_MYSQL_EXTRACT_METHOD] == "relay"
      puts "Creating relay log directory: #{relay_log_dir}"
      Dir.mkdir(relay_log_dir)
    end

    # Create service definition file. 
    generate_svc_properties(@options.service_name)

    puts
    puts "Service creation complete"
    puts "You may now start the service by restarting the replicator"
  end

  # Execute service update.
  def exec_update
    if ! @options.service_name 
      fatal "Service name is required for service update"
    end    

    puts 
    puts "Updating existing replication service: #{@options.service_name}" 
    write_divider

    # Create and validate the static and dynamic file names. 
    static_props = name_of_static_props()
    if ! File.exists?(static_props)
      fatal "Static properties file does not exist; must create service first: #{static_props}"
    end

    # Create service definition file. 
    generate_svc_properties(@options.service_name)

    # Update dynamic properties if desired. 
    dynamic_props = name_of_dynamic_props()
    if File.exists?(dynamic_props) && @options.clear_dynamic
      puts "Removing dynamic properties: #{dynamic_props}"
      File.delete(dynamic_props)
    end

    puts
    puts "Service update complete"
    puts "You may apply the configuration changes by restarting the replicator"
  end

  # Execute service delete.
  def exec_delete
    if ! @options.service_name 
      fatal "Service name is required for service deletion"
    end    

    puts 
    puts "Deleting replication service if it exists: #{@options.service_name}" 
    write_divider

    # Remove property files. 
    static_props = name_of_static_props()
    if File.exists?(static_props)
      # Identify location of tungsten database and delete same. 
      host, port, user, password, service = nil
      File.open(static_props) do |file|
        file.each_line {|line|
          line.strip!
          if line =~ /^replicator.global.db.host=\s*(\S*)/ then
            #puts "Found host=#{$1}"
            host = $1
          elsif line =~ /^replicator.global.db.port=\s*(\S*)/ then
            #puts "Found port=#{$1}"
            port = $1
          elsif line =~ /^replicator.global.db.user=\s*(\S*)/ then
            #puts "Found user=#{$1}"
            user = $1
          elsif line =~ /^replicator.global.db.password=\s*(\S*)/ then
            #puts "Found password=#{$1}"
            password = $1
          elsif line =~ /^service.name=\s*(\S*)/ then
            service = $1
            #puts "Found service=#{service}"
          end
        }
      end

      service_db = "tungsten_" + service
      drop_db = "DROP DATABASE IF EXISTS #{service_db}"
      puts "Attempting to drop service database: #{service_db}"
      mysql = "mysql -u#{user} -p#{password} -h#{host} -P#{port} -e '#{drop_db}'"
      if ! system(mysql)
        puts "WARNING:  Cannot delete Tungsten service database: #{service_db}"
        puts "Use following command to delete:"
        puts "  " + mysql
      end

      puts "Removing static properties: #{static_props}"
      File.delete(static_props)
    end

    dynamic_props = name_of_dynamic_props()
    if File.exists?(dynamic_props)
      puts "Removing dynamic properties: #{dynamic_props}"
      File.delete(dynamic_props)
    end

    # Remove log directory. 
    log_dir = name_of_log_dir()
    if File.exists?(log_dir)
      puts "Removing log directory: #{log_dir}"
      system "rm -r #{log_dir}"
    end

    # Remove relay-log directory.  
    relay_log_dir = name_of_relay_log_dir()
    if File.exists?(relay_log_dir)
      puts "Removing relay log directory: #{relay_log_dir}"
      system "rm -r #{relay_log_dir}"
    end

    puts "Service deletion complete"
  end

  # Create static properties name. 
  def name_of_static_props
    return "tungsten-replicator/conf/static-" + @options.service_name + ".properties"
  end

  # Create dynamic properties name. 
  def name_of_dynamic_props
    return "tungsten-replicator/conf/dynamic-" + @options.service_name + ".properties"
  end

  # Create log directory name.
  def name_of_log_dir
    return config.getProperty(REPL_LOG_DIR) + "/" + @options.service_name
  end

  # Create relay-log directory name.  
  def name_of_relay_log_dir
    return config.getProperty(REPL_RELAY_LOG_DIR) + "/" + @options.service_name
  end

  # Create replication service properties file. 
  def generate_svc_properties(name)
    # Get the log directory names. 
    log_dir = name_of_log_dir()
    relay_log_dir = name_of_relay_log_dir()

    # Determine whether service type.  We take the user's advice but if 
    # none is provided guess by whether it matches against the local service
    # name. 
    if @config.props[REPL_SVC_SERVICE_TYPE]
      service_type = @config.props[REPL_SVC_SERVICE_TYPE]
    elsif name == @config.props[GLOBAL_DSNAME]
      service_type = 'local'
    else
      service_type = 'remote'
    end

    # Create new file. 
    static_props = name_of_static_props()
    puts "Generating service configuration file: #{static_props}"
    transformer = Transformer.new(
      "tungsten-replicator/conf/replicator.properties.service.template", 
      static_props, "#")
    transformer.transform { |line|
      if line =~ /replicator.global.extract.db.host=/ then
        if @config.props[REPL_SVC_EXTRACT_DB_HOST]
          "replicator.global.extract.db.host=" + 
            @config.props[REPL_SVC_EXTRACT_DB_HOST]
        else
          line
        end
      elsif line =~ /replicator.global.extract.db.port=/ then
        if @config.props[REPL_SVC_EXTRACT_DB_PORT]
          "replicator.global.extract.db.port=" + 
            @config.props[REPL_SVC_EXTRACT_DB_PORT]
        else
          line
        end
      elsif line =~ /replicator.global.extract.db.user=/ then
        if @config.props[REPL_SVC_EXTRACT_DB_USER]
          "replicator.global.extract.db.user=" + 
            @config.props[REPL_SVC_EXTRACT_DB_USER]
        else
          line
        end
      elsif line =~ /replicator.global.extract.db.user=/ then
        if @config.props[REPL_SVC_EXTRACT_DB_PORT]
          "replicator.global.extract.db.port=" + 
            @config.props[REPL_SVC_EXTRACT_DB_PORT]
        else
          line
        end
      elsif line =~ /replicator.global.extract.db.password=/ then
        if @config.props[REPL_SVC_EXTRACT_DB_PASSWORD]
          "replicator.global.extract.db.password=" + 
            @config.props[REPL_SVC_EXTRACT_DB_PASSWORD]
        else
          line
        end
      elsif line =~ /replicator.role=/ then
        "replicator.role=" + @config.props[REPL_ROLE]
      elsif line =~ /replicator.nativeSlaveTakeover=/ then
        if @config.props[REPL_SVC_NATIVE_SLAVE_TAKEOVER] == "true"
          "replicator.nativeSlaveTakeover=true"
        else
          "replicator.nativeSlaveTakeover=false"
        end
      elsif line =~ /local.service.name=/ then
        "local.service.name=" + @config.props[GLOBAL_DSNAME]
      elsif line =~ /service.name=/ then
        "service.name=" + name
      elsif line =~ /replicator.service.type=/ then
        "replicator.service.type=" + service_type
      elsif line =~ /replicator.auto_enable/ then
        "replicator.auto_enable=" + @config.props[REPL_AUTOENABLE]
      elsif line =~ /replicator.extractor.mysql.binlogMode/ then
        "replicator.extractor.mysql.binlogMode=" + 
          @config.props[REPL_SVC_BINLOG_MODE]
      elsif line =~ /replicator.master.connect.uri=/ then
        "replicator.master.connect.uri=thl://" + 
          @config.props[REPL_MASTERHOST] + ":" + 
          @config.props[REPL_SVC_MASTERPORT] + "/"
      elsif line =~ /replicator.master.listen.uri=/ then
        "replicator.master.listen.uri=thl://" + 
          @config.props[GLOBAL_HOST] + ":" + 
          @config.props[REPL_SVC_THL_PORT] + "/"
      elsif line =~ /replicator.store.thl.storageListenerUri=/ then
        "replicator.store.thl.storageListenerUri=thl://0.0.0.0:" + 
          @config.props[REPL_SVC_THL_PORT] + "/"
      elsif line =~ /replicator.extractor.mysql.useRelayLogs=/
        if @config.props[REPL_MYSQL_EXTRACT_METHOD] == "relay"
          "replicator.extractor.mysql.useRelayLogs=true"
        else
          "replicator.extractor.mysql.useRelayLogs=false"
        end
      elsif line =~ /replicator.extractor.mysql.relayLogDir=/ && @config.props[REPL_MYSQL_EXTRACT_METHOD] == "relay"
        "replicator.extractor.mysql.relayLogDir=" + relay_log_dir
      elsif line =~ /replicator.global.apply.channels=/
        "replicator.global.apply.channels=" + @config.props[REPL_SVC_CHANNELS]
      elsif line =~ /replicator.global.buffer.size=/
        "replicator.global.buffer.size=" + @config.props[REPL_BUFFER_SIZE]
      elsif line =~ /replicator.store.thl.doChecksum=/
        "replicator.store.thl.doChecksum=" + @config.props[REPL_THL_DO_CHECKSUM]
      elsif line =~ /replicator.store.thl.logConnectionTimeout=/
        "replicator.store.thl.logConnectionTimeout=" + @config.props[REPL_THL_LOG_CONNECTION_TIMEOUT]
      elsif line =~ /replicator.store.thl.log_dir=/
        "replicator.store.thl.log_dir="+ log_dir
      elsif line =~ /replicator.store.thl.log_file_size=/
        "replicator.store.thl.log_file_size=" + @config.props[REPL_THL_LOG_FILE_SIZE]
      elsif line =~ /replicator.store.parallel-queue=/ then
        # Switch between disk and in-memory parallelization.
        if @config.props[REPL_SVC_PARALLELIZATION_TYPE] == "memory"
          "replicator.store.parallel-queue=com.continuent.tungsten.replicator.storage.parallel.ParallelQueueStore"
        else
          "replicator.store.parallel-queue=com.continuent.tungsten.replicator.thl.THLParallelQueue"
        end
      elsif line =~ /replicator.extractor.parallel-q-extractor=/ then
        if @config.props[REPL_SVC_PARALLELIZATION_TYPE] == "memory"
          "replicator.extractor.parallel-q-extractor=com.continuent.tungsten.replicator.storage.parallel.ParallelQueueExtractor"
        else
          "replicator.extractor.parallel-q-extractor=com.continuent.tungsten.replicator.thl.THLParallelQueueExtractor"
        end
      elsif line =~ /replicator.applier.parallel-q-applier=/ then
        if @config.props[REPL_SVC_PARALLELIZATION_TYPE] == "memory"
          "replicator.applier.parallel-q-applier=com.continuent.tungsten.replicator.storage.parallel.ParallelQueueApplier"
        else
          "replicator.applier.parallel-q-applier=com.continuent.tungsten.replicator.thl.THLParallelQueueApplier"
        end
      elsif line =~ /replicator.shard.default.db=/
        "replicator.shard.default.db=" + @config.props[REPL_SVC_SHARD_DEFAULT_DB]
      elsif line =~ /replicator.filter.bidiSlave.allowBidiUnsafe=/
        "replicator.filter.bidiSlave.allowBidiUnsafe=" + @config.props[REPL_SVC_ALLOW_BIDI_UNSAFE]
      elsif line =~ /replicator.filter.bidiSlave.allowAnyRemoteService=/
        "replicator.filter.bidiSlave.allowAnyRemoteService=" + @config.props[REPL_SVC_ALLOW_ANY_SERVICE]
      elsif line =~ /replicator.filter.shardfilter.enforceHome=/
        "replicator.filter.shardfilter.enforceHome=" + @config.props[REPL_SVC_ENFORCE_HOME]
      else
        line
      end
    }
  end

  # Write a header
  def write_header(content)
    puts "#####################################################################"
    printf "# %s\n", content
    puts "#####################################################################"
  end

  # Write a sub-divider, which is used between sections under a single header.
  def write_divider
    puts "---------------------------------------------------------------------"
  end

  # Signal a fatal error. 
  def fatal(message)
    puts message
    exit 1
  end
end
