variable "name" {
  description = "unique prefix for names. alpha numeric only. ie uatAppname"
  type        = string
  default     = ""
}

variable "scope" {
  type = string // CLOUDFRONT, REGIONAL
}

# Note: defaultAction variable removed - was unused (see main.tf line 15 TODO comment)

variable "requestThreshold" {
  description = "If you chose yes for the Activate HTTP Flood Protection parameter, enter the maximum acceptable requests per FIVE-minute period per IP address. AWS WAF rate-based rules accept a limit of 10 or more (if you chose Lambda/Athena log parser options, you can use any value greater than zero). If you chose to deactivate this protection, ignore this parameter. Default to `2000`."
  type        = number
  default     = 2000
}

variable "errorThreshold" {
  description = "If you chose yes for the Activate Scanners & Probes Protection parameter, enter the maximum acceptable bad requests per minute per IP. If you chose to deactivate this protection protection, ignore this parameter."
  type        = number
  default     = 50
}

variable "blockPeriod" {
  description = "If you chose yes for the Activate Scanners & Probes Protection or HTTP Flood Lambda/Athena log parser parameters, enter the period (in minutes) to block applicable IP addresses. If you chose to deactivate log parsing, ignore this parameter."
  type        = number
  default     = 240
}

variable "excluded_rules" {
  type    = list(string)
  default = []
}

variable "path_rate_rules" {
  description = "Extra per-address rate rules, each limited to one HTTP method and one URI path (optionally a query string fragment). Map key = rule name suffix (rule name is <name>wafRate<key>). Count mode only in this release. Window is the AWS default, 300 seconds. See docs/DECISIONS.md."
  type = map(object({
    priority       = number # 10-19, unique across entries
    limit          = number # requests per 300 s per address; AWS minimum is 10
    action         = string # "count" only in this release
    method         = string # matched EXACTLY, for example "POST"
    uri_path_regex = string # matched after URL_DECODE, NORMALIZE_PATH, LOWERCASE; 1-512 chars
    query_contains = string # "" = no query condition; else CONTAINS match after URL_DECODE
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : r.limit >= 10 && floor(r.limit) == r.limit])
    error_message = "path_rate_rules: limit must be a whole number of 10 or more (AWS WAF minimum)."
  }

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : r.action == "count"])
    error_message = "path_rate_rules: action must be \"count\". Block is a later release with its own review."
  }

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : r.priority >= 10 && r.priority <= 19 && floor(r.priority) == r.priority])
    error_message = "path_rate_rules: priority must be a whole number from 10 to 19 (other numbers are used by the module's own rules)."
  }

  validation {
    condition     = length(distinct([for r in values(var.path_rate_rules) : r.priority])) == length(var.path_rate_rules)
    error_message = "path_rate_rules: each entry needs a unique priority."
  }

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : length(r.uri_path_regex) >= 1 && length(r.uri_path_regex) <= 512])
    error_message = "path_rate_rules: uri_path_regex must be 1 to 512 characters."
  }
}

//variable "rules" {
//  type = list(map)
//  default = []
//}

variable "uploadToS3Activated" {
  type    = bool
  default = false
}

variable "uploadToS3Path" {
  type        = string
  description = "path that upload will take place"
  default     = ""
}

variable "uploadToS3Method" {
  type        = string
  description = "method that upload will use"
  default     = "PUT"
}

variable "whitelistActivated" {
  type    = bool
  default = false
}

variable "blacklistProtectionActivated" {
  type    = bool
  default = true
}

variable "httpFloodProtectionLogParserActivated" {
  type    = bool
  default = true
}

variable "scannersProbesProtectionActivated" {
  type    = bool
  default = true
}

variable "reputationListsProtectionActivated" {
  type    = bool
  default = true
}

variable "badBotProtectionActivated" {
  type    = bool
  default = true
}

# Note: SqlInjectionProtectionSensitivityLevelParam removed - re-add when implementing
# sensitivity_level in main.tf sqli_match_statement blocks (currently commented out)

variable "logging_bucket" {
  description = "S3 bucket for WAF logs"
  type        = string
  default     = ""
}

variable "dead_letter_arn" {
  type = string
}

variable "dead_letter_policy_arn" {
  type = string
}

variable "kms_master_key_id" {
  type    = string
  default = null
}
variable "kms_master_key_arn" {
  type    = string
  default = null
}

