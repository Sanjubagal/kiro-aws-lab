###############################################################
# SECRETS MANAGER & SSM PARAMETER STORE
# Free: SSM Parameter Store standard parameters (always free)
# Note: Secrets Manager has a 30-day free trial then $0.40/secret/mo
###############################################################

# Secrets Manager - DB Password (30-day free trial)
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${local.name}/db/password"
  description             = "RDS master password for Kiro lab"
  recovery_window_in_days = 0 # Immediate deletion for lab
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "admin"
    password = var.db_password
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = "labdb"
  })
}

# SSM Parameter Store - Free standard parameters
resource "aws_ssm_parameter" "app_env" {
  name  = "/kiro-lab/app/environment"
  type  = "String"
  value = "lab"
  tags  = local.tags
}

resource "aws_ssm_parameter" "app_version" {
  name  = "/kiro-lab/app/version"
  type  = "String"
  value = "1.0.0"
  tags  = local.tags
}

resource "aws_ssm_parameter" "db_host" {
  name  = "/kiro-lab/db/host"
  type  = "String"
  value = aws_db_instance.mysql.address
  tags  = local.tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/kiro-lab/db/name"
  type  = "String"
  value = "labdb"
  tags  = local.tags
}

resource "aws_ssm_parameter" "api_url" {
  name  = "/kiro-lab/api/url"
  type  = "String"
  value = "https://${aws_api_gateway_rest_api.lab.id}.execute-api.${var.region}.amazonaws.com/lab"
  tags  = local.tags
}

resource "aws_ssm_parameter" "sns_topic_arn" {
  name  = "/kiro-lab/sns/alerts-arn"
  type  = "String"
  value = aws_sns_topic.alerts.arn
  tags  = local.tags
}

resource "aws_ssm_parameter" "feature_flags" {
  name  = "/kiro-lab/features/flags"
  type  = "String"
  value = jsonencode({ logging = true, metrics = true, tracing = true, alerts = true })
  tags  = local.tags
}
