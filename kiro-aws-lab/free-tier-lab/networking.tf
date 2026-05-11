###############################################################
# NETWORKING - VPC, Subnets, IGW, Route Tables
# Free: VPC, Subnets, IGW, Route Tables, Security Groups, NACLs
###############################################################

# VPC
resource "aws_vpc" "lab" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(local.tags, { Name = "${local.name}-vpc" })
}

# Public Subnets (3 AZs)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${local.name}-public-a", Tier = "public" })
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.region}b"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${local.name}-public-b", Tier = "public" })
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "${var.region}c"
  map_public_ip_on_launch = true
  tags = merge(local.tags, { Name = "${local.name}-public-c", Tier = "public" })
}

# Private Subnets (2 AZs for RDS multi-AZ requirement)
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "${var.region}a"
  tags = merge(local.tags, { Name = "${local.name}-private-a", Tier = "private" })
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "${var.region}b"
  tags = merge(local.tags, { Name = "${local.name}-private-b", Tier = "private" })
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = merge(local.tags, { Name = "${local.name}-public-rt" })
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

# Private Route Table (no internet - for RDS/private resources)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(local.tags, { Name = "${local.name}-private-rt" })
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}

# Network ACL (custom - free)
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.lab.id
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id, aws_subnet.public_c.id]

  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }
  ingress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.my_ip
    from_port  = 22
    to_port    = 22
  }
  ingress {
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
  tags = merge(local.tags, { Name = "${local.name}-public-nacl" })
}

# VPC Flow Logs (free for basic - logs to CloudWatch)
resource "aws_flow_log" "vpc" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.lab.id
  tags            = merge(local.tags, { Name = "${local.name}-flow-logs" })
}

# VPC Endpoint for S3 (free - no data transfer charges within VPC)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]
  tags              = merge(local.tags, { Name = "${local.name}-s3-endpoint" })
}

# VPC Endpoint for DynamoDB (free)
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.private.id]
  tags              = merge(local.tags, { Name = "${local.name}-dynamodb-endpoint" })
}
