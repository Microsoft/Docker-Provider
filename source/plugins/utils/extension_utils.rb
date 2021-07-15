# Copyright (c) Microsoft Corporation.  All rights reserved.
#!/usr/local/bin/ruby
# frozen_string_literal: true

require_relative "extension"                    

class ExtensionUtils
    class << self        
        def getOutputStreamId(dataType)  
          outputStreamId = "" 
          begin
            if !dataType.nil? && !dataType.empty?
              outputStreamId = Extension.instance.get_output_stream_id(dataType)  
              $log.info("ExtensionUtils::getOutputStreamId: got streamid: #{outputStreamId} for datatype: #{dataType}")
            else           
              $log.warn("ExtensionUtils::getOutputStreamId: dataType shouldnt be nil or empty")
            end            
          rescue => errorStr
            $log.warn("ExtensionUtils::getOutputStreamId: failed with an exception: #{errorStr}")
          end    
          return outputStreamId     
        end 
        def isAADMSIAuthMode() 
          return !ENV["AAD_MSI_AUTH_MODE"].nil? && !ENV["AAD_MSI_AUTH_MODE"].empty? && ENV["AAD_MSI_AUTH_MODE"].downcase == "true"
        end        
    end
end
