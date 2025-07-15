
class Imagemagick < ActiveRecord::Base
  include Action, ModuleSshTools
  
  CMD_CONVERT='convert'
  CMD_IDENTIFY='identify'
  CMD_SCRIPT='run script'
  CMD_COMPOSITE='composite'
  COMMANDS=[CMD_CONVERT, CMD_IDENTIFY, CMD_COMPOSITE]#, CMD_SCRIPT]

  VAR_SOURCE_FILE_PATH="Media_file_path"
  VAR_OPTIONS ="Options"
  VAR_COMMAND_ARGUMENTS="Command_arguments"
  VAR_EXECUTION_NODE = "Imagemagick_node"
  VAR_EXECUTION_LOGIN = "Execution_login"
  VAR_EXECUTION_PASSWORD = "Execution_password"
  VAR_EXECUTABLE_FOLDER_PATH = "Binaries_folder_path"

  OUT_RESULTS="Image_info"

  DEFAULT_BINARY_PATH="" #"/opt/local/bin/"

  

  #Revision history
  # => 0.0.1 initial release, only supports convert and identify
  # => 0.0.2 adds functionality to mask password
  # => 0.0.3 adds support for spaces in filenames
  # => 0.0.4 adds support for composite command (used for watermarking)
  # => 0.0.5 preventing autocomplete of user info by browsers
  # => 0.0.6 fix runtime specification of execution node
  # => 0.0.7 2015-02-17 ML - ignores i/o line that are not parsed correctly
  # => 0.0.8 2015-02-24 ML - New icon
  # => 0.0.9 2016-06-07 JG - Adding Remote Node Dependency
  def self.version
    return 0, 0, 9
  end


  # Completion of ModuleSshTools
  

  def parse_error(data)
    @stderr = "" if (@stderr == nil)
    @outputs ={} if (@outputs == nil)
    @stderr << data
    if data.match(/\n/) != nil
      case
      when (command_get == CMD_IDENTIFY)
        info "Imagemagick reported: #{@stderr} on its stderr"
      when (command_get == CMD_CONVERT)
        if (command_line_get.match(/-verbose/) != nil)
          #NOTE: the verbose output of convert is on stderr
          results = format_file_convert(@stderr)
          @outputs[OUT_RESULTS] = results if (results.size != 0)
        else
          info "Imagemagick reported: #{data} on its stderr"
        end
      end
    end
  end

  
  def read_progress(data)
    return nil, nil
  end


  #return processedOutputs, status_details
  def process_outputs(execution_outputs)
    results = {}
    case
    when (command_get == CMD_IDENTIFY)
      if (command_line_get.match(/-verbose/) != nil)
        results[OUT_RESULTS] = format_file_info(execution_outputs)
      else
        results[OUT_RESULTS] = {"Image"=>media_file_path_get, "Properties"=>execution_outputs}
      end
    when (command_get == CMD_CONVERT)
      if (command_line_get.match(/-verbose/) == nil) #verbose goes to stderr
        results[OUT_RESULTS] = {"Image"=>media_file_path_get, "Properties"=>execution_outputs}
      end
    end

    return results, "done with analysis of '#{File.basename(media_file_path_get)}'"
  end




  #Completion of action and plugin specific methods


  def outputs_spec
    {OUT_RESULTS => TYPE_HASH}
  end

  def inputs_spec
    @required_hash = {}
    @optional_hash = {}
    if media_file_path.blank?
      @required_hash[VAR_SOURCE_FILE_PATH]=TYPE_STRING
    else
      variables = Payload.variables(media_file_path)
      variables.each { |variable|
        @required_hash[variable]=TYPE_STRING
      }
    end

    if options.blank?
      @optional_hash[VAR_OPTIONS]=TYPE_STRING
    else
      variables = Payload.variables(options)
      variables.each { |variable|
        @required_hash[variable]=TYPE_STRING
      }
    end
    if command_arguments.blank?
      @optional_hash[VAR_COMMAND_ARGUMENTS]=TYPE_STRING
    else
      variables = Payload.variables(command_arguments)
      variables.each { |variable|
        @required_hash[variable]=TYPE_STRING
      }
    end
    if execution_node.blank?
      @required_hash[VAR_EXECUTION_NODE] = TYPE_STRING
      @optional_hash[VAR_EXECUTION_LOGIN] = TYPE_STRING
      @optional_hash[VAR_EXECUTION_PASSWORD] = TYPE_STRING
      @optional_hash[VAR_EXECUTABLE_FOLDER_PATH] = TYPE_STRING
    end
    return @required_hash, @optional_hash
  end

  def category
    [CATEGORY_FILETRANSFORMATIONS]
  end

  def description
    "This action plug-in can be used to retrieve media information about an image or apply transformation to that image using the popular imagemagick application."
  end

  def dependencies
    return [{:entity => "RemoteNode", :id_key => "name", :id_value => execution_node, :dependent_field => "execution_node"}]
  end

  #Executes the action associated with the WorkStep identified by stateId
  #returns nil if the execution is in progress (asynchronous) or the status of the execution if the action was executed synchronously
  def execute
    @execution_output = ""
    command_line = command_line_get
    info command_line
    @outputs = {}

    @status, @status_details, exec_outputs = remote_execute_and_close!(execution_node_get, command_line)
    #debug "exec_outputs #{@status}  #{@status_details} #{exec_outputs} -- #{@outputs}"
    if @status == Action::STATUS_COMPLETE
      return @status, "Imagemagick #{command_get} completed for #{media_file_path_get}", @outputs
    end

    return @status, "Imagemagick #{command_get} failed for #{media_file_path_get}", @outputs
  end

  def imagemagick_executable
    binary_dir = binary_path_get
    return (binary_dir.blank? ? command_get : File.join(binary_dir, command_get))
  end

  def command_line_get
    return "#{imagemagick_executable} #{options_get} #{media_file_path_get.double_quote} #{command_arguments_get}"
  end


  def options_get
    exec_options = default_get(:options)
    if exec_options.blank?
      case
      when (command_get == CMD_IDENTIFY)
        return "-verbose"
      when (command_get == CMD_CONVERT)
        return "-verbose"
      else
        return ''
      end
    else
      return exec_options
    end
  end

  def binary_path_get
    return default_get(:binary_path)
  end

  def command_get
    return default_get(:command)
  end


  def media_file_path_get
    if @inputs.present? and @inputs[VAR_SOURCE_FILE_PATH].present?
      @inputs[VAR_SOURCE_FILE_PATH]
    else
      return "" if media_file_path.blank?
      Payload.expand(media_file_path, @inputs, self)
    end
  end

  def command_arguments_get
    return default_get(:command_arguments)
  end


  def format_file_info(fileDesc)
    results={}
    past_indent=0
    group = {}
    cursor= nil
    fileDesc.each_line {|line|
      begin
        matcher =line.match(/( *)([A-Za-z ]+): *(.*)/)
        next if (matcher == nil)
        indent = matcher[1].size
        if (indent == 0)
          results[matcher[2]] = matcher[3]
          indent = 2
          cursor=results
        else
          case
          when (indent == past_indent)
            if matcher[3] == ''
              cursor[matcher[2]] = {}
              cursor = cursor[matcher[2]]
              group[indent] = cursor
            else
              cursor[matcher[2]] = matcher[3]
            end
          when (indent > past_indent)
            if matcher[3] == ''
              cursor[matcher[2]] = {}
              cursor = cursor[matcher[2]]
              group[indent] = cursor
            else
              cursor[matcher[2]] = matcher[3]
            end
          when (indent < past_indent)
            cursor = group[indent]
            if matcher[3] == ''
              cursor[matcher[2]] = {}
              cursor = cursor[matcher[2]]
              group[indent] = cursor
            else
              cursor[matcher[2]] = matcher[3]
            end
          end

        end
        past_indent =indent
      rescue Exception => e
        warn "Line: '#{line}' could not be parsed and was ignored"
      end
    }
    return results
  end


  #/opt/aspera/orchestrator/Boots.JPG JPEG 3072x2304 3072x2304+0+0 8-bit DirectClass 1.051MB 0.300u 0:00.600
  #/opt/aspera/orchestrator/Boots.JPG=>/opt/aspera/orchestrator/Boots_small.png JPEG 3072x2304=>1536x1152 1536x1152+0+0 8-bit DirectClass 3.637MB 1.750u 0:20.480
  def format_file_convert(convDesc)
    results={}
    convDesc.each_line{|line|
      matcher = line.match(/(.*?)=>(.*?) (.*)/)
      next if matcher == nil
      results ={"Image"=>matcher[1], "Converted_Image"=>matcher[2], "Properties"=>matcher[3]}
    }
    return results
  end

  def execution_node_get
    if execution_node.blank?
      return  @inputs[VAR_EXECUTION_NODE]
    else
      return execution_node
    end
  end

end
