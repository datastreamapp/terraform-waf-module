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
  description = "Extra per-address rate rules, each limited to one HTTP method and one URI path (optionally a query string fragment). Map key = rule name suffix (rule name is <name>wafRate<key>). At most 9 entries (AWS allows 10 rate-based rules per web ACL; the flood rule uses one). Count mode only in this release. Window is the AWS default, 300 seconds. See docs/DECISIONS.md."
  type = map(object({
    priority       = number # 10-19, unique across entries
    limit          = number # requests per 300 s per address; 10 to 2,000,000,000 (below 100 needs hashicorp/aws >= 5.66.0)
    action         = string # "count" only in this release
    method         = string # upper-case HTTP method, matched EXACTLY and case-sensitively, for example "POST"
    uri_path_regex = string # matched after URL_DECODE, NORMALIZE_PATH_WIN, LOWERCASE; 1-200 chars (AWS quota); no upper-case letters outside escapes; no literal backslash
    query_contains = string # "" = no query condition; else CONTAINS match after URL_DECODE; printable ASCII, max 200
  }))
  default = {}

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : r.limit >= 10 && r.limit <= 2000000000 && floor(r.limit) == r.limit])
    error_message = "path_rate_rules: limit must be a whole number from 10 (AWS WAF minimum) to 2000000000."
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
    condition     = alltrue([for r in values(var.path_rate_rules) : length(r.uri_path_regex) >= 1 && length(r.uri_path_regex) <= 200])
    error_message = "path_rate_rules: uri_path_regex must be 1 to 200 characters (AWS WAF regex pattern quota)."
  }

  validation {
    # Remove each escape pair (a backslash and a non-backslash, so \S or \d stay
    # allowed), then reject any backslash that is left: that is a literal
    # backslash, and NORMALIZE_PATH_WIN turns every "\" in the path into "/",
    # so it could never match. Uses regexall, not strcontains (Terraform 1.5),
    # to keep the module's ">= 1.0" floor.
    condition     = alltrue([for r in values(var.path_rate_rules) : length(regexall("\\\\", replace(r.uri_path_regex, "/\\\\[^\\\\]/", ""))) == 0])
    error_message = "path_rate_rules: uri_path_regex must not match a literal backslash. NORMALIZE_PATH_WIN turns every \\ in the path into /, so it can never match."
  }

  validation {
    # Remove each escape pair (a backslash and the next character, so \S or \D
    # are allowed), then look for an upper-case letter. The path is lower-cased
    # before the match, so an upper-case literal could never match.
    condition     = alltrue([for r in values(var.path_rate_rules) : !can(regex("[A-Z]", replace(r.uri_path_regex, "/\\\\./", "")))])
    error_message = "path_rate_rules: uri_path_regex must not contain upper-case letters outside escapes such as \\d or \\S. The path is lower-cased before the match, so an upper-case letter never matches."
  }

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : contains(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"], r.method)])
    error_message = "path_rate_rules: method must be an upper-case HTTP method such as \"POST\" (WAF matches it exactly and case-sensitively)."
  }

  validation {
    condition     = alltrue([for k in keys(var.path_rate_rules) : can(regex("^[A-Za-z0-9]{1,64}$", k))])
    error_message = "path_rate_rules: each key must be 1 to 64 letters or digits (it becomes part of the WAF rule and metric name)."
  }

  validation {
    condition     = length(var.path_rate_rules) <= 9
    error_message = "path_rate_rules: at most 9 entries. AWS allows 10 rate-based rules per web ACL and the module's flood rule uses one."
  }

  validation {
    condition     = alltrue([for r in values(var.path_rate_rules) : can(regex("^[ -~]{0,200}$", r.query_contains))])
    error_message = "path_rate_rules: query_contains must be printable ASCII, at most 200 characters (AWS byte match limit)."
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

