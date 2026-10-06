# Tests for the path_rate_rules input (datastreamapp/issues#2252).
#
# Runs fully offline: the AWS provider is mocked, every run is `command = plan`,
# and no credentials or AWS calls are needed. Needs Terraform 1.7 or newer
# (mock_provider). Run with `make test-terraform` or `terraform test`.
#
# The ACL's `rule` blocks are a set, so each assertion picks one rule by name
# and checks the values it carries, not only that a rule exists.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-x86_64:1"
    }
  }

  # Four aws_iam_policy_document data sources (main.tf x2, lambda.log-parser.tf,
  # lambda.reputation-list.tf). A valid policy keeps any JSON check happy.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name                   = "test"
  scope                  = "CLOUDFRONT"
  dead_letter_arn        = "arn:aws:sqs:us-east-1:123456789012:mock-dlq"
  dead_letter_policy_arn = "arn:aws:iam::123456789012:policy/mock-dlq"
  kms_master_key_id      = "00000000-0000-0000-0000-000000000000"
  kms_master_key_arn     = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
}

# ---------------------------------------------------------------------------
# 1. Input unset: the rule names and priorities are exactly today's.
# ---------------------------------------------------------------------------
run "input_unset_keeps_todays_rules" {
  command = plan

  assert {
    condition = toset([for r in aws_wafv2_web_acl.main.rule : r.name]) == toset([
      "testwafAWSManagedRulesCommonRuleSet",
      "testwafBlacklistRule",
      "testwafHttpFloodRateBasedRule",
      "testwafSqlInjectionRule",
      "testwafXssRule",
    ])
    error_message = "With path_rate_rules unset, the rule names must equal today's five rules."
  }

  assert {
    condition = { for r in aws_wafv2_web_acl.main.rule : r.name => r.priority } == {
      "testwafAWSManagedRulesCommonRuleSet" = 1
      "testwafBlacklistRule"                = 4
      "testwafHttpFloodRateBasedRule"       = 5
      "testwafSqlInjectionRule"             = 20
      "testwafXssRule"                      = 30
    }
    error_message = "With path_rate_rules unset, the rule priorities must equal today's."
  }
}

# Same check with the switches the edge root uses (uploadToS3Activated = true).
run "input_unset_keeps_todays_rules_edge_switches" {
  command = plan

  variables {
    uploadToS3Activated = true
    uploadToS3Path      = "/upload"
  }

  assert {
    condition = toset([for r in aws_wafv2_web_acl.main.rule : r.name]) == toset([
      "testwafUploadToS3Rule",
      "testwafAWSManagedRulesCommonRuleSet",
      "testwafBlacklistRule",
      "testwafHttpFloodRateBasedRule",
      "testwafSqlInjectionRule",
      "testwafXssRule",
    ])
    error_message = "With path_rate_rules unset and uploads on, the rule names must equal today's six rules."
  }
}

# ---------------------------------------------------------------------------
# 2. Payload: the two rules from plan 3.1 carry the right values.
# ---------------------------------------------------------------------------
run "payload_two_rules" {
  command = plan

  variables {
    path_rate_rules = {
      RecoveryCode = {
        priority       = 10
        limit          = 30
        action         = "count"
        method         = "POST"
        uri_path_regex = "^/(en-ca|fr-ca)/login/recovery-code/?$"
        query_contains = ""
      }
      OnboardRecoverySend = {
        priority       = 11
        limit          = 30
        action         = "count"
        method         = "POST"
        uri_path_regex = "^/(en-ca|fr-ca)/onboard/?$"
        query_contains = "/sendRecoveryCode"
      }
    }
  }

  # --- rule set as a whole ---
  assert {
    condition = toset([for r in aws_wafv2_web_acl.main.rule : r.name]) == toset([
      "testwafAWSManagedRulesCommonRuleSet",
      "testwafBlacklistRule",
      "testwafHttpFloodRateBasedRule",
      "testwafSqlInjectionRule",
      "testwafXssRule",
      "testwafRateRecoveryCode",
      "testwafRateOnboardRecoverySend",
    ])
    error_message = "Two entries must add exactly two rules, named <name>wafRate<key>, and keep the existing five."
  }

  # Exact name => priority map. All seven priorities differ, so this also proves
  # no collision with the module's own rules. (length() and distinct() over the
  # rule set are unknown at plan time: the blacklist rule carries IP set ARNs
  # that only exist after apply, so the set size is not known yet.)
  assert {
    condition = { for r in aws_wafv2_web_acl.main.rule : r.name => r.priority } == {
      "testwafAWSManagedRulesCommonRuleSet" = 1
      "testwafBlacklistRule"                = 4
      "testwafHttpFloodRateBasedRule"       = 5
      "testwafRateRecoveryCode"             = 10
      "testwafRateOnboardRecoverySend"      = 11
      "testwafSqlInjectionRule"             = 20
      "testwafXssRule"                      = 30
    }
    error_message = "Rule priorities must be the module's own (1, 4, 5, 20, 30) plus 10 and 11 for the new rules."
  }

  # --- RecoveryCode ---
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.priority if r.name == "testwafRateRecoveryCode"]) == 10
    error_message = "RecoveryCode priority must be 10."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].limit if r.name == "testwafRateRecoveryCode"]) == 30
    error_message = "RecoveryCode limit must be 30."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].aggregate_key_type if r.name == "testwafRateRecoveryCode"]) == "IP"
    error_message = "RecoveryCode must aggregate by IP (never FORWARDED_IP, a client can set that header)."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : length(r.action[0].count) if r.name == "testwafRateRecoveryCode"]) == 1
    error_message = "RecoveryCode must have a count action."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule :
      length(r.action[0].block) + length(r.action[0].allow) + length(r.action[0].captcha) + length(r.action[0].challenge)
    if r.name == "testwafRateRecoveryCode"]) == 0
    error_message = "RecoveryCode must not block, allow, captcha or challenge (Count only in this release)."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : r.visibility_config[0] if r.name == "testwafRateRecoveryCode"]) == {
      cloudwatch_metrics_enabled = true
      metric_name                = "testwafRateRecoveryCode"
      sampled_requests_enabled   = true
    }
    error_message = "RecoveryCode visibility: metrics and sampled requests on, metric name equal to the rule name."
  }

  # Scope-down: exactly two statements for RecoveryCode (method, path), no query.
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : length(r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement) if r.name == "testwafRateRecoveryCode"]) == 2
    error_message = "RecoveryCode scope-down must AND exactly two statements (method and path) when query_contains is empty."
  }

  # Statement 0: method POST, EXACTLY.
  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : {
      search   = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[0].byte_match_statement[0].search_string
      position = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[0].byte_match_statement[0].positional_constraint
      method   = length(r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[0].byte_match_statement[0].field_to_match[0].method)
    } if r.name == "testwafRateRecoveryCode"]) == { search = "POST", position = "EXACTLY", method = 1 }
    error_message = "RecoveryCode scope-down statement 0 must be a byte match on the method, EXACTLY \"POST\"."
  }

  # Statement 1: regex on uri_path.
  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : {
      regex = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[1].regex_match_statement[0].regex_string
      path  = length(r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[1].regex_match_statement[0].field_to_match[0].uri_path)
    } if r.name == "testwafRateRecoveryCode"]) == { regex = "^/(en-ca|fr-ca)/login/recovery-code/?$", path = 1 }
    error_message = "RecoveryCode scope-down statement 1 must be a regex match on uri_path with the configured pattern."
  }

  # Path transformations: URL_DECODE, NORMALIZE_PATH_WIN, LOWERCASE, in that order.
  # NORMALIZE_PATH_WIN also turns "\" into "/", which the app's URL parser does too.
  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : {
      for t in r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[1].regex_match_statement[0].text_transformation : tostring(t.priority) => t.type
    } if r.name == "testwafRateRecoveryCode"]) == { "0" = "URL_DECODE", "1" = "NORMALIZE_PATH_WIN", "2" = "LOWERCASE" }
    error_message = "RecoveryCode path match must apply URL_DECODE (0), NORMALIZE_PATH_WIN (1), LOWERCASE (2) and nothing else."
  }

  # --- OnboardRecoverySend ---
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.priority if r.name == "testwafRateOnboardRecoverySend"]) == 11
    error_message = "OnboardRecoverySend priority must be 11."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].limit if r.name == "testwafRateOnboardRecoverySend"]) == 30
    error_message = "OnboardRecoverySend limit must be 30."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : length(r.action[0].count) if r.name == "testwafRateOnboardRecoverySend"]) == 1
    error_message = "OnboardRecoverySend must have a count action."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule :
      length(r.action[0].block) + length(r.action[0].allow) + length(r.action[0].captcha) + length(r.action[0].challenge)
    if r.name == "testwafRateOnboardRecoverySend"]) == 0
    error_message = "OnboardRecoverySend must not block, allow, captcha or challenge."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : length(r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement) if r.name == "testwafRateOnboardRecoverySend"]) == 3
    error_message = "OnboardRecoverySend scope-down must AND three statements (method, path, query)."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : {
      search   = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[0].byte_match_statement[0].search_string
      position = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[0].byte_match_statement[0].positional_constraint
    } if r.name == "testwafRateOnboardRecoverySend"]) == { search = "POST", position = "EXACTLY" }
    error_message = "OnboardRecoverySend scope-down statement 0 must be EXACTLY \"POST\" on the method."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[1].regex_match_statement[0].regex_string if r.name == "testwafRateOnboardRecoverySend"]) == "^/(en-ca|fr-ca)/onboard/?$"
    error_message = "OnboardRecoverySend scope-down statement 1 must carry the onboard path regex."
  }

  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : {
      for t in r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[1].regex_match_statement[0].text_transformation : tostring(t.priority) => t.type
    } if r.name == "testwafRateOnboardRecoverySend"]) == { "0" = "URL_DECODE", "1" = "NORMALIZE_PATH_WIN", "2" = "LOWERCASE" }
    error_message = "OnboardRecoverySend path match must apply URL_DECODE, NORMALIZE_PATH_WIN, LOWERCASE in that order."
  }

  # Statement 2: query string CONTAINS "/sendRecoveryCode" after URL_DECODE.
  assert {
    condition = one([for r in aws_wafv2_web_acl.main.rule : {
      search   = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[2].byte_match_statement[0].search_string
      position = r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[2].byte_match_statement[0].positional_constraint
      query    = length(r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[2].byte_match_statement[0].field_to_match[0].query_string)
      tt = {
        for t in r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[2].byte_match_statement[0].text_transformation : tostring(t.priority) => t.type
      }
    } if r.name == "testwafRateOnboardRecoverySend"]) == { search = "/sendRecoveryCode", position = "CONTAINS", query = 1, tt = { "0" = "URL_DECODE" } }
    error_message = "OnboardRecoverySend scope-down statement 2 must be a CONTAINS \"/sendRecoveryCode\" byte match on the query string after URL_DECODE."
  }

  # The existing flood rule is untouched.
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].limit if r.name == "testwafHttpFloodRateBasedRule"]) == 2000
    error_message = "The existing flood rule limit must stay at the requestThreshold default (2000)."
  }
}

# ---------------------------------------------------------------------------
# 3. Different keys give different rule names (no collision).
# ---------------------------------------------------------------------------
run "different_keys_different_names" {
  command = plan

  variables {
    path_rate_rules = {
      A = { priority = 12, limit = 10, action = "count", method = "POST", uri_path_regex = "^/a$", query_contains = "" }
      B = { priority = 13, limit = 10, action = "count", method = "POST", uri_path_regex = "^/a$", query_contains = "" }
    }
  }

  assert {
    condition     = length([for r in aws_wafv2_web_acl.main.rule : r.name if startswith(r.name, "testwafRate")]) == 2
    error_message = "Two keys must create two rate rules."
  }

  # Seven distinct names, including both keys, means the two keys did not collapse
  # into one rule name.
  assert {
    condition = toset([for r in aws_wafv2_web_acl.main.rule : r.name]) == toset([
      "testwafAWSManagedRulesCommonRuleSet",
      "testwafBlacklistRule",
      "testwafHttpFloodRateBasedRule",
      "testwafSqlInjectionRule",
      "testwafXssRule",
      "testwafRateA",
      "testwafRateB",
    ])
    error_message = "Keys A and B must give two distinct rules, testwafRateA and testwafRateB."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].limit if r.name == "testwafRateA"]) == 10
    error_message = "The AWS minimum limit (10) must be accepted and passed through."
  }
}

# ---------------------------------------------------------------------------
# 4. Validation: every bad value is rejected by var.path_rate_rules.
# ---------------------------------------------------------------------------
run "reject_limit_below_10" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 9, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_action_block" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "block", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_action_other" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "allow", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_priority_below_range" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 5, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_priority_above_range" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 20, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_duplicate_priority" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
      Y = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/y$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_empty_regex" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_regex_over_512" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/${join("", [for i in range(512) : "a"])}$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

# Boundary positive: 19 is the top of the allowed range and 512 chars is allowed.
run "accept_boundaries" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 19, limit = 10, action = "count", method = "POST", uri_path_regex = join("", [for i in range(512) : "a"]), query_contains = "" }
    }
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.priority if r.name == "testwafRateX"]) == 19
    error_message = "Priority 19, limit 10 and a 512-character regex must be accepted."
  }
}

# ---------------------------------------------------------------------------
# 5. Round 2 validation (reviews of datastreamapp/issues#2252 chunk A).
#    These are MODULE validations: they run under the mocked provider. The
#    provider's own argument checks (regex syntax, metric-name characters,
#    limit range) do NOT run under mock_provider; the caller's real
#    `terraform plan` is the first place those are checked.
# ---------------------------------------------------------------------------

# method: WAF matches it EXACTLY and case-sensitively, so only upper-case
# HTTP methods are accepted.
run "reject_method_lowercase" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "post", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_method_mixedcase" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "Post", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_method_empty" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_method_misspelled" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "POTS", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

# uri_path_regex: the path is lower-cased before the match, so an upper-case
# literal can never match. Escape sequences such as \d and \S are allowed.
run "reject_regex_uppercase" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/(EN-ca|fr-ca)/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "accept_regex_with_uppercase_escapes" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "GET", uri_path_regex = "^/(en-ca|fr-ca)/x/\\d+/\\S*\\W?\\D?$", query_contains = "" }
    }
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[1].regex_match_statement[0].regex_string if r.name == "testwafRateX"]) == "^/(en-ca|fr-ca)/x/\\d+/\\S*\\W?\\D?$"
    error_message = "A regex whose only upper-case letters are inside escapes (\\S, \\W, \\D) must be accepted and passed through unchanged."
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[0].byte_match_statement[0].search_string if r.name == "testwafRateX"]) == "GET"
    error_message = "Another upper-case HTTP method (GET) must be accepted."
  }
}

# Map key: becomes part of the WAF rule and metric name.
run "reject_key_with_space" {
  command = plan
  variables {
    path_rate_rules = {
      "Bad Key" = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_key_over_64" {
  command = plan
  variables {
    path_rate_rules = {
      (join("", [for i in range(65) : "k"])) = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

# Entry count: AWS allows 10 rate-based rules per web ACL and the flood rule
# already uses one. Ten entries with ten unique priorities fail only this check.
run "reject_ten_entries" {
  command = plan
  variables {
    path_rate_rules = { for i in range(10) : "R${i}" => { priority = 10 + i, limit = 30, action = "count", method = "POST", uri_path_regex = "^/r${i}$", query_contains = "" } }
  }
  expect_failures = [var.path_rate_rules]
}

run "accept_nine_entries" {
  command = plan
  variables {
    path_rate_rules = { for i in range(9) : "R${i}" => { priority = 10 + i, limit = 30, action = "count", method = "POST", uri_path_regex = "^/r${i}$", query_contains = "" } }
  }
  assert {
    condition     = { for r in aws_wafv2_web_acl.main.rule : r.name => r.priority if startswith(r.name, "testwafRate") } == { for i in range(9) : "testwafRateR${i}" => 10 + i }
    error_message = "Nine entries must give nine rate rules, testwafRateR0..R8 at priorities 10..18."
  }
}

# Whole numbers (exercises the floor() terms on their own).
run "reject_limit_not_whole" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 10.5, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "reject_priority_not_whole" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10.5, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

# Limit upper bound (AWS and provider maximum 2,000,000,000).
run "reject_limit_above_max" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 2000000001, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = "" }
    }
  }
  expect_failures = [var.path_rate_rules]
}

# query_contains: byte match search string is at most 200 bytes (AWS API).
# Printable ASCII only, so characters equal bytes.
run "reject_query_over_200" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 30, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = join("", [for i in range(201) : "q"]) }
    }
  }
  expect_failures = [var.path_rate_rules]
}

run "accept_limits_at_max" {
  command = plan
  variables {
    path_rate_rules = {
      X = { priority = 10, limit = 2000000000, action = "count", method = "POST", uri_path_regex = "^/x$", query_contains = join("", [for i in range(200) : "q"]) }
    }
  }
  assert {
    condition     = one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].limit if r.name == "testwafRateX"]) == 2000000000
    error_message = "limit 2,000,000,000 (the maximum) must be accepted."
  }
  assert {
    condition     = length(one([for r in aws_wafv2_web_acl.main.rule : r.statement[0].rate_based_statement[0].scope_down_statement[0].and_statement[0].statement[2].byte_match_statement[0].search_string if r.name == "testwafRateX"])) == 200
    error_message = "A 200-character query_contains (the maximum) must be accepted."
  }
}
