###############################################################
# SECURITY GROUPS - Free
###############################################################

# Web/App Security Group
resource "aws_security_group" "web" {
  name        = "${local.name}-web-sg"
  description = "Web server security group"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
    description = "SSH from my IP"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-web-sg" })
}

# App Security Group (internal only)
resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "App tier security group"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
    description     = "From web tier"
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
    description = "SSH from my IP"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-app-sg" })
}

# RDS Security Group
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "RDS security group"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id, aws_security_group.app.id, aws_security_group.lambda.id]
    description     = "MySQL from app/web/lambda"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-rds-sg" })
}

# Lambda Security Group
resource "aws_security_group" "lambda" {
  name        = "${local.name}-lambda-sg"
  description = "Lambda security group"
  vpc_id      = aws_vpc.lab.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-lambda-sg" })
}
