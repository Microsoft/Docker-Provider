package extension

// AgentTaggedDataResponse struct for response from AgentTaggedData request
type AgentTaggedDataResponse struct {
	Request     string `json:"Request"`
	RequestID   string `json:"RequestId"`
	Version     string `json:"Version"`
	Success     bool   `json:"Success"`
	Description string `json:"Description"`
	TaggedData  string `json:"TaggedData"`
}

// TaggedData structure for respone
type TaggedData struct {
	SchemaVersion           int                         `json:"schemaVersion"`
	Version                 int                         `json:"version"`
	ExtensionName           string                      `json:"extensionName"`
	ExtensionConfigs        []ExtensionConfig           `json:"extensionConfigurations"`
	OutputStreamDefinitions map[string]StreamDefinition `json:"outputStreamDefinitions"`
}

// StreamDefinition structure for named pipes
type StreamDefinition struct {
	NamedPipe string `json:"namedPipe"`
}

// ExtensionConfig structure for extension definition in DCR
type ExtensionConfig struct {
	ID                string                 `json:"id"`
	OriginIds         []string               `json:"originIds"`
	ExtensionSettings map[string]interface{} `json:"extensionSettings"`
	InputStreams      map[string]interface{} `json:"inputStreams"`
	OutputStreams     map[string]interface{} `json:"outputStreams"`
}
