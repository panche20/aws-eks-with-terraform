variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "cluster_ca_certificate" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "alb_controller_role_arn" { type = string }
variable "ebs_csi_role_arn" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
