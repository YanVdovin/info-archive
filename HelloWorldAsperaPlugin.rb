#require 'action'
class HelloWorld < ActiveRecord::Base
  include Action

  PROMPT_OVERRIDE="prompt_override"
  DEFAULT_PROMPT="Hello World"
  DEFAULT_TEMPO=2
  PROGRESS_FILE="#{BASE_DIR}/hello_world_PROGRESS"
  TEMPO="tempo"
  MESSAGE="message"

  # Provides the version, subversion and release number.
  # That same information can be accessed using the method 'release' which
  #  returns the data in the "1.1.0" format instead.
  def self.version
    return 1, 1, 0
  end

  # return a hash of required gems.{<gem_name>=><gem_release>}
  #  for example [['net-scp','1.0.2'], ['aspera_ruby'], ['logging','1.4.3+']]
  def self.dependencies
    return [] #nothing required at this point.
  end

  # Required inputs are defined by the pattern provided ('prompt' data field in
  #  the supporting activeRecord instance).
  # Additional optional inputs can be added to override default behavior ('tempo')
  #  or to override the DB message pattern to replace it with a run-time value.
  def inputs_spec
    required_inputs={}
    variables=parsePrompt
    variables.each{|variable_name|
      required_inputs[variable_name]="string"
    }
    return required_inputs,{PROMPT_OVERRIDE=>"string",TEMPO=>'int'}
  end


  # The only input provided is the constructed message.
  def outputs_spec
    return {MESSAGE=>'string'}
  end


  # If get_prompt is not overriden, then the default validation can be used,
  #  otherwise, the validation must be done against the actual expected inputs as
  #  determined by the run-time value of the prompt pattern
  def validate_inputs(inputsHash=@inputs)
    if inputsHash[PROMPT_OVERRIDE] == nil
      #get_prompt is not overriden so default validation can be used
      return default_inputs_validation(inputsHash)
    else
      variables=parsePrompt(inputsHash[PROMPT_OVERRIDE])
      variables.each{|variable_name|
        return false if inputsHash[variable_name]==nil #variable not found
      }
      #all variables required to expand the overriden get_prompt are found in the inputs
      return true 
    end
  end

  # A sub-category is created in 'Other' to indicates that this plug-in is just
  #  a reference implementation not doing anything useful.
  def category
    #[CATEGORY_OTHER,"Code Samples"]
    ["Code Samples"]
  end

  def description
    return "This is a reference implementation for a simple Action plugin illustrating the API."
  end

  def help
    return "This action returns a string that represent a message constructed at "\
      + "execution time by parsing the prompt (either stored in the DB, or provided "\
      + "at execution time using the PROMPT_OVERRIDE optional input variable. "\
      + "The prompt string use can contain static text and variable expanded at "\
      + "run-time. Variable are indicated using the syntax <%=variable_name%> "\
      + "embedded into static text. For example \\\"Hello <%=name%>.\\\" "
  end

  # Timeout is a function of the message length and of the delay between letters.
  def timeout
    message = expandPrompt((@inputs != nil)?@inputs : {})
    return 60 + (get_tempo * message.length) # a buffer of 60 seconds is added just in case
  end

  def timeout_help
    return "The timeout is calculated by multiplying the length of the message by the delay between letters. 60 seconds are added as a buffer."
  end

  # Execution method for the plugin. Here the execution consists in constructing
  #  the output message based on the provided pattern and run-time variable values.
  # The message is processed letter by letter, with a specified delay betweeen each
  #  letter and the status is updated each time.
  # Since Pause/Resume and Cancel are provided, support for these actions is included.
  def execute
    message = expandPrompt(@inputs)
    @processedMessage=''
    @isPaused=false

    if processMessage(message,0)==true
      return @status, @status_details, @outputs
    else
      return Action::STATUS_ERROR, "Unexpected loop termination", {MESSAGE=>@processedMessage}
    end
  end


  def recover
    begin
      retrieveState      
      message = expandPrompt(@inputs)
      index=@processedMessage.length
      if processMessage(message,index)==true
        return @status, @status_details, @outputs
      else
        return Action::STATUS_ERROR, "Unexpected loop termination", {MESSAGE=>@processedMessage}
      end
    rescue Exception => e
      return Action::STATUS_ERROR, "Could not recover - #{e.inspect}", {}
    end
  end



  # Notifies that the action has been paused, when the pause is initiated.
  # Does not have anything else to do as processing and pausing of processing is
  #  handled in execute
  def pause
    #only notify once
    report_progress(Action::STATUS_PAUSED,progressMessage("Paused...")) unless @isPaused
    @isPaused = true
    return true
  end

  # Updates the status variables to reflect that a cancel request was made.
  # Does not have anything else to do as processing and aborting processing is
  #  handled in execute
  def cancel
    @status=Action::STATUS_FAILED
    @status_details="Action Canceled"
    @outputs={MESSAGE=>@processedMessage}
    return true
  end

  #No actions required, the execution of the resume action is handled in the execute 
  # upon notification that pausing is not requested anymore.
  def resume
    return true
  end

  # rollback differs from the previous actions as it is called after execute is complete,
  #  however, here there is not much to do
  def rollback
    begin
      File.delete("#{PROGRESS_FILE}_#{state_id}") if File.exist?("#{PROGRESS_FILE}_#{state_id}")
      #Since this action does not modify anything, there is not really anything to do to roll-back
      report_progress(Action::STATUS_FAILED,"Rolling back requested")
      return true
    rescue Exception => e
      log "HelloWorld: rolling back failed - #{e.inspect}"
      return false
    end
  end



  #Additional Plugin-specific methods

  # Core execution methods - Process the message line by line and notifies of the
  #  progress made.
  def processMessage(message,index)
    i=index #tracks the number of letter processed
    execTempo = get_tempo
    while (true) do
      case
      when i==message.size #Processing is done, no need to send notification
        @status= Action::STATUS_COMPLETE
        @status_details="Message: #{@processedMessage}"
        @outputs={MESSAGE=>@processedMessage}
        return true
      when must_cancel?
        cancel
        @status=Action::STATUS_FAILED
        @status_details="Action was canceled at #{Time.now}"
        @outputs={MESSAGE=>@processedMessage}
        return true
      when must_pause?
        pause
      else #normal processing cycle (includes 'resume')
        @isPaused=false
        i=i+1
        @processedMessage=message[0,i]
        persistState #the object actively request its current state to be persisted
        report_progress(Action::STATUS_INPROGRESS,progressMessage("In Progress..."))
      end
      sleep(execTempo)
    end
    return false
  end
  private :processMessage


  # Formats the status detail message to reflect progresses
  def progressMessage(progressStatus)
    return "Building Message: '#{@processedMessage}' - #{progressStatus}"
  end
  private :progressMessage

  # Expands the variables within the prompt pattern by replacing them with their run-time value.
  def expandPrompt(inputsHash)
    myPrompt=((inputsHash[PROMPT_OVERRIDE]==nil)?get_prompt : inputsHash[PROMPT_OVERRIDE])
    variables=parsePrompt(myPrompt)
    message=myPrompt
    variables.each {|variable_name|
      message.gsub!(Regexp.new("<%= *"+variable_name+" *%>"),inputsHash[variable_name])
    }
    return message
  end
  private :expandPrompt



  # Returns the list of variable names used in the prompt pattern
  def parsePrompt(myPrompt=get_prompt)
    variables=[]
    matching_sections = myPrompt.scan(/<%= *([A-Za-z_0-9]*) *%>/)
    matching_sections.each{|matching_section|
      variables << matching_section[0]
    }
    return variables.uniq
  end
  private :parsePrompt


  # Provides the Prompt pattern set-up in the DB or a default value.
  def get_prompt
    return ((prompt.blank? == false)?prompt : DEFAULT_PROMPT)
  end
  private :get_prompt


  def persistState
    fPersist = File.open("#{PROGRESS_FILE}_#{state_id}", "w")
    fPersist.puts @processedMessage
    fPersist.close
  end
  private :persistState

  def retrieveState
    begin
      @processedMessage =""
      File.open("#{PROGRESS_FILE}_#{state_id}", "r") { |f|
        @processedMessage = f.read
      }
    rescue
      @processedMessage =""
    end
    return @processedMessage
  end
  private :retrieveState


  def get_tempo
    return ((@inputs==nil or @inputs[TEMPO]==nil)?((tempo == nil)?DEFAULT_TEMPO : tempo) : @inputs[TEMPO])
  end

end
