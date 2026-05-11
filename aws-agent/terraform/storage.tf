###############################################################
# STORAGE
# Free: S3 (5GB), EBS (30GB gp2), Glacier (10GB)
###############################################################

# --- S3 BUCKETS ---

# Main assets bucket
resource "aws_s3_bucket" "assets" {
  bucket        = "${local.name}-assets"
  force_destroy = true
  tags          = merge(local.tags, { Name = "${local.name}-assets" })
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    id     = "archive-old-objects"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "GLACIER" # Free: 10GB Glacier
    }
    expiration { days = 90 }
  }
}

# Logs bucket
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name}-logs"
  force_destroy = true
  tags          = merge(local.tags, { Name = "${local.name}-logs" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lambda code bucket
resource "aws_s3_bucket" "lambda_code" {
  bucket        = "${local.name}-lambda-code"
  force_destroy = true
  tags          = merge(local.tags, { Name = "${local.name}-lambda-code" })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lambda_code" {
  bucket = aws_s3_bucket.lambda_code.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "lambda_code" {
  bucket                  = aws_s3_bucket.lambda_code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 bucket notification to SQS
resource "aws_s3_bucket_notification" "assets" {
  bucket = aws_s3_bucket.assets.id
  queue {
    queue_arn     = aws_sqs_queue.s3_events.arn
    events        = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix = "uploads/"
  }
  depends_on = [aws_sqs_queue_policy.s3_events]
}

# Upload a sample object
resource "aws_s3_object" "sample" {
  bucket  = aws_s3_bucket.assets.id
  key     = "uploads/sample.json"
  content = jsonencode({ message = "Hello from Kiro Free Tier Lab", timestamp = "2026-04-16" })
  content_type = "application/json"
  tags    = local.tags
}
