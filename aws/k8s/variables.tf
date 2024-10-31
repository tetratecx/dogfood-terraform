variable "name_prefix" {
  type        = string
  description = "name prefix"
}

variable "cidr" {
  type        = string
  description = "cidr"
}

variable "min_az_count" {
  type    = string
  default = 2
}

variable "max_az_count" {
  type    = string
  default = 3
}

variable "cluster_name" {
  type        = string
  description = "cluster name"
}

variable "region" {
  type = string
}

variable "k8s_version" {
  type = string
}

variable "instance_type" {
  type = string
}

variable "tags" {
  type = map(any)
}

variable "lb_controller_helm_chart_version" {
  default = "1.7.1"
}

variable "lb_controller_settings" {
  default = { "controllerConfig" = { "featureGates" = { "SubnetsClusterTagCheck" : "false" } } }
}
