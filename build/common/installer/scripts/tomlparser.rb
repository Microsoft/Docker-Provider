#!/usr/local/bin/ruby

#this should be require relative in Linux and require in windows, since it is a gem install on windows
@os_type = ENV["OS_TYPE"]
if !@os_type.nil? && !@os_type.empty? && @os_type.strip.casecmp("windows") == 0
  require "tomlrb"
else
  require_relative "tomlrb"
end

require_relative "ConfigParseErrorLogger"

@configMapMountPath = "/etc/config/settings/log-data-collection-settings"
@configVersion = ""
@configSchemaVersion = ""
# Setting default values which will be used in case they are not set in the configmap or if configmap doesnt exist
@collectStdoutLogs = true
@stdoutExcludeNamespaces = "kube-system"
@collectStderrLogs = true
@stderrExcludeNamespaces = "kube-system"
@collectClusterEnvVariables = true
@logTailPath = "/var/log/containers/*.log"
@logExclusionRegexPattern = "(^((?!stdout|stderr).)*$)"
@logStitchMultiline = false
@excludePath = "*.csv2" #some invalid path
@enrichContainerLogs = false
@containerLogSchemaVersion = ""
@collectAllKubeEvents = false
@containerLogsRoute = "v2" # default for linux
if !@os_type.nil? && !@os_type.empty? && @os_type.strip.casecmp("windows") == 0
  @containerLogsRoute = "v1" # default is v1 for windows until windows agent integrates windows ama
end
# Use parser to parse the configmap toml file to a ruby structure
def parseConfigMap
  begin
    # Check to see if config map is created
    if (File.file?(@configMapMountPath))
      puts "config::configmap container-azm-ms-agentconfig for settings mounted, parsing values"
      parsedConfig = Tomlrb.load_file(@configMapMountPath, symbolize_keys: true)
      puts "config::Successfully parsed mounted config map"
      return parsedConfig
    else
      puts "config::configmap container-azm-ms-agentconfig for settings not mounted, using defaults"
      @excludePath = "*_kube-system_*.log"
      return nil
    end
  rescue => errorStr
    ConfigParseErrorLogger.logError("Exception while parsing config map for log collection/env variable settings: #{errorStr}, using defaults, please check config map for errors")
    @excludePath = "*_kube-system_*.log"
    return nil
  end
end

# Use the ruby structure created after config parsing to set the right values to be used as environment variables
def populateSettingValuesFromConfigMap(parsedConfig)
  if !parsedConfig.nil? && !parsedConfig[:log_collection_settings].nil?
    #Get stdout log config settings
    begin
      if !parsedConfig[:log_collection_settings][:stdout].nil? && !parsedConfig[:log_collection_settings][:stdout][:enabled].nil?
        @collectStdoutLogs = parsedConfig[:log_collection_settings][:stdout][:enabled]
        puts "config::Using config map setting for stdout log collection"
        stdoutNamespaces = parsedConfig[:log_collection_settings][:stdout][:exclude_namespaces]

        #Clearing it, so that it can be overridden with the config map settings
        @stdoutExcludeNamespaces.clear
        if @collectStdoutLogs && !stdoutNamespaces.nil?
          if stdoutNamespaces.kind_of?(Array)
            # Checking only for the first element to be string because toml enforces the arrays to contain elements of same type
            if stdoutNamespaces.length > 0 && stdoutNamespaces[0].kind_of?(String)
              #Empty the array to use the values from configmap
              stdoutNamespaces.each do |namespace|
                if @stdoutExcludeNamespaces.empty?
                  # To not append , for the first element
                  @stdoutExcludeNamespaces.concat(namespace)
                else
                  @stdoutExcludeNamespaces.concat("," + namespace)
                end
              end
              puts "config::Using config map setting for stdout log collection to exclude namespace"
            end
          end
        end
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for stdout log collection - #{errorStr}, using defaults, please check config map for errors")
    end

    #Get stderr log config settings
    begin
      if !parsedConfig[:log_collection_settings][:stderr].nil? && !parsedConfig[:log_collection_settings][:stderr][:enabled].nil?
        @collectStderrLogs = parsedConfig[:log_collection_settings][:stderr][:enabled]
        puts "config::Using config map setting for stderr log collection"
        stderrNamespaces = parsedConfig[:log_collection_settings][:stderr][:exclude_namespaces]
        stdoutNamespaces = Array.new
        #Clearing it, so that it can be overridden with the config map settings
        @stderrExcludeNamespaces.clear
        if @collectStderrLogs && !stderrNamespaces.nil?
          if stderrNamespaces.kind_of?(Array)
            if !@stdoutExcludeNamespaces.nil? && !@stdoutExcludeNamespaces.empty?
              stdoutNamespaces = @stdoutExcludeNamespaces.split(",")
            end
            # Checking only for the first element to be string because toml enforces the arrays to contain elements of same type
            if stderrNamespaces.length > 0 && stderrNamespaces[0].kind_of?(String)
              stderrNamespaces.each do |namespace|
                if @stderrExcludeNamespaces.empty?
                  # To not append , for the first element
                  @stderrExcludeNamespaces.concat(namespace)
                else
                  @stderrExcludeNamespaces.concat("," + namespace)
                end
                # Add this namespace to excludepath if both stdout & stderr are excluded for this namespace, to ensure are optimized and dont tail these files at all
                if stdoutNamespaces.include? namespace
                  @excludePath.concat("," + "*_" + namespace + "_*.log")
                end
              end
              puts "config::Using config map setting for stderr log collection to exclude namespace"
            end
          end
        end
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for stderr log collection - #{errorStr}, using defaults, please check config map for errors")
    end

    #Get environment variables log config settings
    begin
      if !parsedConfig[:log_collection_settings][:env_var].nil? && !parsedConfig[:log_collection_settings][:env_var][:enabled].nil?
        @collectClusterEnvVariables = parsedConfig[:log_collection_settings][:env_var][:enabled]
        puts "config::Using config map setting for cluster level environment variable collection"
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for cluster level environment variable collection - #{errorStr}, using defaults, please check config map for errors")
    end

    #Get container log enrichment setting
    begin
      if !parsedConfig[:log_collection_settings][:enrich_container_logs].nil? && !parsedConfig[:log_collection_settings][:enrich_container_logs][:enabled].nil?
        @enrichContainerLogs = parsedConfig[:log_collection_settings][:enrich_container_logs][:enabled]
        puts "config::Using config map setting for cluster level container log enrichment"
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for cluster level container log enrichment - #{errorStr}, using defaults, please check config map for errors")
    end

     #Get container log schema version setting
     begin
      if !parsedConfig[:log_collection_settings][:schema].nil? && !parsedConfig[:log_collection_settings][:schema][:containerlog_schema_version].nil?
        @containerLogSchemaVersion = parsedConfig[:log_collection_settings][:schema][:containerlog_schema_version]
        puts "config::Using config map setting for container log schema version"
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for container log schema version - #{errorStr}, using defaults, please check config map for errors")
    end
    
    # Get multiline log stitching setting
    begin
      if !parsedConfig[:log_collection_settings][:stitch_multiline_logs].nil? && !parsedConfig[:log_collection_settings][:stitch_multiline_logs][:enabled].nil?
        @logStitchMultiline = parsedConfig[:log_collection_settings][:stitch_multiline_logs][:enabled]
        puts "config::Using config map setting for exception stack multiline logging"
      else
        # Turn on multiline by default if using ContainerLogV2 schema
        if @containerLogSchemaVersion.strip.casecmp("v2")
          @logStitchMultiline = true
        else
          @logStitchMultiline = false
        end
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for stitching multiline logs - #{errorStr}, using defaults, please check config map for errors")
    end

    #Get kube events enrichment setting
    begin
      if !parsedConfig[:log_collection_settings][:collect_all_kube_events].nil? && !parsedConfig[:log_collection_settings][:collect_all_kube_events][:enabled].nil?
        @collectAllKubeEvents = parsedConfig[:log_collection_settings][:collect_all_kube_events][:enabled]
        puts "config::Using config map setting for kube event collection"
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for kube event collection - #{errorStr}, using defaults, please check config map for errors")
    end

    #Get container logs route setting
    begin
      if !parsedConfig[:log_collection_settings][:route_container_logs].nil? && !parsedConfig[:log_collection_settings][:route_container_logs][:version].nil?
        if !parsedConfig[:log_collection_settings][:route_container_logs][:version].empty?
           @containerLogsRoute = parsedConfig[:log_collection_settings][:route_container_logs][:version]
           puts "config::Using config map setting for container logs route: #{@containerLogsRoute}"
        else 
           puts "config::Ignoring config map settings and using default value since provided container logs route value is empty"    
        end         
      end
    rescue => errorStr
      ConfigParseErrorLogger.logError("Exception while reading config map settings for container logs route - #{errorStr}, using defaults, please check config map for errors")
    end

  end
end

@configSchemaVersion = ENV["AZMON_AGENT_CFG_SCHEMA_VERSION"]
puts "****************Start Config Processing********************"
if !@configSchemaVersion.nil? && !@configSchemaVersion.empty? && @configSchemaVersion.strip.casecmp("v1") == 0 #note v1 is the only supported schema version , so hardcoding it
  configMapSettings = parseConfigMap
  if !configMapSettings.nil?
    populateSettingValuesFromConfigMap(configMapSettings)
  end
else
  if (File.file?(@configMapMountPath))
    ConfigParseErrorLogger.logError("config::unsupported/missing config schema version - '#{@configSchemaVersion}' , using defaults, please use supported schema version")
  end
  @excludePath = "*_kube-system_*.log"
end

# Write the settings to file, so that they can be set as environment variables
file = File.open("config_env_var", "w")

if !file.nil?
  # This will be used in td-agent-bit.conf file to filter out logs
  if (!@collectStdoutLogs && !@collectStderrLogs)
    #Stop log tailing completely
    @logTailPath = "/opt/nolog*.log"
    @logExclusionRegexPattern = "stdout|stderr"
  elsif !@collectStdoutLogs
    @logExclusionRegexPattern = "stdout"
  elsif !@collectStderrLogs
    @logExclusionRegexPattern = "stderr"
  end
  file.write("export AZMON_COLLECT_STDOUT_LOGS=#{@collectStdoutLogs}\n")
  file.write("export AZMON_LOG_TAIL_PATH=#{@logTailPath}\n")
  file.write("export AZMON_LOG_EXCLUSION_REGEX_PATTERN=\"#{@logExclusionRegexPattern}\"\n")
  file.write("export AZMON_LOG_STITCH_MULTILINE=#{@logStitchMultiline}\n")
  file.write("export AZMON_STDOUT_EXCLUDED_NAMESPACES=#{@stdoutExcludeNamespaces}\n")
  file.write("export AZMON_COLLECT_STDERR_LOGS=#{@collectStderrLogs}\n")
  file.write("export AZMON_STDERR_EXCLUDED_NAMESPACES=#{@stderrExcludeNamespaces}\n")
  file.write("export AZMON_CLUSTER_COLLECT_ENV_VAR=#{@collectClusterEnvVariables}\n")
  file.write("export AZMON_CLUSTER_LOG_TAIL_EXCLUDE_PATH=#{@excludePath}\n")
  file.write("export AZMON_CLUSTER_CONTAINER_LOG_ENRICH=#{@enrichContainerLogs}\n")
  file.write("export AZMON_CLUSTER_COLLECT_ALL_KUBE_EVENTS=#{@collectAllKubeEvents}\n")
  file.write("export AZMON_CONTAINER_LOGS_ROUTE=#{@containerLogsRoute}\n")
  file.write("export AZMON_CONTAINER_LOG_SCHEMA_VERSION=#{@containerLogSchemaVersion}\n")
  # Close file after writing all environment variables
  file.close
  puts "Both stdout & stderr log collection are turned off for namespaces: '#{@excludePath}' "
  puts "****************End Config Processing********************"
else
  puts "Exception while opening file for writing config environment variables"
  puts "****************End Config Processing********************"
end


=begin
This section generates the file that will set the environment variables for windows. This script will be called by the main.ps1 script
which is the ENTRYPOINT script for the windows aks log container
=end

def get_command_windows(env_variable_name, env_variable_value)
  return "[System.Environment]::SetEnvironmentVariable(\"#{env_variable_name}\", \"#{env_variable_value}\", \"Process\")" + "\n" + "[System.Environment]::SetEnvironmentVariable(\"#{env_variable_name}\", \"#{env_variable_value}\", \"Machine\")" + "\n"
end

if !@os_type.nil? && !@os_type.empty? && @os_type.strip.casecmp("windows") == 0
  # Write the settings to file, so that they can be set as environment variables
  file = File.open("setenv.ps1", "w")

  if !file.nil?

    # This path format is necessary for fluent-bit in windows
    if @logStitchMultiline
      @logTailPath = "C:\\var\\log\\containers\\*.log"
    end

    commands = get_command_windows('AZMON_COLLECT_STDOUT_LOGS', @collectStdoutLogs)
    file.write(commands)
    commands = get_command_windows('AZMON_LOG_TAIL_PATH', @logTailPath)
    file.write(commands)
    commands = get_command_windows('AZMON_LOG_EXCLUSION_REGEX_PATTERN', @logExclusionRegexPattern)
    file.write(commands)
    commands = get_command_windows('AZMON_LOG_STITCH_MULTILINE', @logStitchMultiline)
    file.write(commands)
    commands = get_command_windows('AZMON_STDOUT_EXCLUDED_NAMESPACES', @stdoutExcludeNamespaces)
    file.write(commands)
    commands = get_command_windows('AZMON_COLLECT_STDERR_LOGS', @collectStderrLogs)
    file.write(commands)
    commands = get_command_windows('AZMON_STDERR_EXCLUDED_NAMESPACES', @stderrExcludeNamespaces)
    file.write(commands)
    commands = get_command_windows('AZMON_CLUSTER_COLLECT_ENV_VAR', @collectClusterEnvVariables)
    file.write(commands)
    commands = get_command_windows('AZMON_CLUSTER_LOG_TAIL_EXCLUDE_PATH', @excludePath)
    file.write(commands)
    commands = get_command_windows('AZMON_CLUSTER_CONTAINER_LOG_ENRICH', @enrichContainerLogs)
    file.write(commands)
    commands = get_command_windows('AZMON_CLUSTER_COLLECT_ALL_KUBE_EVENTS', @collectAllKubeEvents)
    file.write(commands)
    commands = get_command_windows('AZMON_CONTAINER_LOGS_ROUTE', @containerLogsRoute)
    file.write(commands)
    commands = get_command_windows('AZMON_CONTAINER_LOG_SCHEMA_VERSION', @containerLogSchemaVersion)
    file.write(commands)

    # Close file after writing all environment variables
    file.close
    puts "Both stdout & stderr log collection are turned off for namespaces: '#{@excludePath}' "
    puts "****************End Config Processing********************"
  else
    puts "Exception while opening file for writing config environment variables for WINDOWS LOG"
    puts "****************End Config Processing********************"
  end
end