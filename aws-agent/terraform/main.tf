###############################################################
# AWS Free Tier Complex Lab - Full Agent Testing Environment
# Covers ALL free tier eligible resources
# Region: ap-south-1
###############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  suffix = random_id.suffix.hex
  name   = "freetier-lab-${local.suffix}"
  tags = {
    Project     = "kiro-free-tier-lab"
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
