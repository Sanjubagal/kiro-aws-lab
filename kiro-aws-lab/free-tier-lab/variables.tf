variable "region" {
  description = "AWS region"
  default     = "ap-south-1"
}

variable "my_ip" {
  description = "Your public IP for SSH access (e.g. 1.2.3.4/32)"
  default     = "0.0.0.0/0" # Change this to your IP for security
}

variable "db_password" {
  description = "RDS master password"
  default     = "LabPassword123!"
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key content for EC2 key pair"
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC0 placeholder-replace-with-your-key"
}


variable "alert_email" {
  description = "Email for SNS alerts"
  default     = "your@email.com"
}
