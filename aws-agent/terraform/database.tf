###############################################################
# DATABASE
# Free: RDS 750hrs/mo db.t2.micro (MySQL/PostgreSQL/MariaDB)
#       DynamoDB 25GB storage + 25 RCU/WCU (always free)
###############################################################

# --- RDS MySQL (Free Tier: 750hrs/mo db.t2.micro, 20GB storage) ---

resource "aws_db_subnet_group" "lab" {
  name       = "${local.name}-db-subnet"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  tags       = merge(local.tags, { Name = "${local.name}-db-subnet-group" })
}

resource "aws_db_instance" "mysql" {
  identifier              = "${local.name}-mysql"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  storage_type            = "gp2"
  storage_encrypted       = true
  username                = "admin"
  password                = var.db_password
  db_name                 = "labdb"
  db_subnet_group_name    = aws_db_subnet_group.lab.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  backup_retention_period = 0
  deletion_protection     = false
  multi_az                = false

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  tags = merge(local.tags, { Name = "${local.name}-mysql" })
}

# --- DynamoDB Tables (Always Free: 25GB, 25 RCU/WCU) ---

# Users table
resource "aws_dynamodb_table" "users" {
  name           = "${local.name}-users"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "userId"
  range_key      = "email"

  attribute {
    name = "userId"
    type = "S"
  }
  attribute {
    name = "email"
    type = "S"
  }
  attribute {
    name = "createdAt"
    type = "S"
  }

  global_secondary_index {
    name            = "email-index"
    hash_key        = "email"
    projection_type = "ALL"
    read_capacity   = 5
    write_capacity  = 5
  }

  local_secondary_index {
    name            = "createdAt-index"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery { enabled = true }

  tags = merge(local.tags, { Name = "${local.name}-users" })
}

# Events/Audit table
resource "aws_dynamodb_table" "events" {
  name           = "${local.name}-events"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "eventId"
  range_key      = "timestamp"

  attribute {
    name = "eventId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }
  attribute {
    name = "eventType"
    type = "S"
  }

  global_secondary_index {
    name            = "eventType-timestamp-index"
    hash_key        = "eventType"
    range_key       = "timestamp"
    projection_type = "ALL"
    read_capacity   = 5
    write_capacity  = 5
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = merge(local.tags, { Name = "${local.name}-events" })
}

# Config/Settings table
resource "aws_dynamodb_table" "config" {
  name           = "${local.name}-config"
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  hash_key       = "configKey"

  attribute {
    name = "configKey"
    type = "S"
  }

  tags = merge(local.tags, { Name = "${local.name}-config" })
}

# Seed some data into DynamoDB
resource "aws_dynamodb_table_item" "config_item" {
  table_name = aws_dynamodb_table.config.name
  hash_key   = aws_dynamodb_table.config.hash_key

  item = jsonencode({
    configKey   = { S = "app-settings" }
    environment = { S = "lab" }
    version     = { S = "1.0.0" }
    features    = { M = {
      logging   = { BOOL = true }
      metrics   = { BOOL = true }
      tracing   = { BOOL = true }
    }}
  })
}
