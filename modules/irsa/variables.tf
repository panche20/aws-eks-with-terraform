variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }
variable "environment" {
  type    = string
  default = "dev"
}
variable "tags" {
  type    = map(string)
  default = {}
}
