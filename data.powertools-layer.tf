data "aws_ssm_parameter" "powertools_layer" {
  name = "/aws/service/powertools/python/x86_64/python3.13/latest"
}
