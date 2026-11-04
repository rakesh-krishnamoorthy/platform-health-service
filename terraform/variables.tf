variable "region" {
  description = "AWS region (this account is only allowed to use ap-southeast-2)"
  type        = string
  default     = "ap-southeast-2"
}

variable "instance_type" {
  description = "EC2 instance type - keep it free tier"
  type        = string
  default     = "t3.micro"
}

variable "image" {
  description = "Container image the instance pulls and runs (built and pushed by CI)"
  type        = string
  default     = "ghcr.io/rakesh-krishnamoorthy/platform-health-service:latest"
}
