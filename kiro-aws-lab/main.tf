provider "aws" {
  region = "ap-south-1"
}

resource "aws_vpc" "lab" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "kiro-lab-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.lab.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = { Name = "public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-south-1a"
  tags              = { Name = "private-subnet-a" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-south-1b"
  tags              = { Name = "private-subnet-b" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.lab.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    gateway_id     = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "rta" {
  subnet_id = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "web_sg" {
  name   = "web-sg"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-sg"
  }
}


resource "aws_instance" "web1" {
  ami = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  subnet_id = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  tags = { Name = "web-1" }
  user_data = <<-EOF
              #!/bin/bash
              apt update -y
              apt install -y nginx
              systemctl enable nginx
              EOF
}

resource "aws_instance" "web2" {
  ami = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  subnet_id = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  tags = { Name = "web-2" }
  lifecycle { create_before_destroy = true }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

resource "aws_db_subnet_group" "db" {
  name       = "kiro-lab-db-subnet"
  subnet_ids = [aws_subnet.private.id, aws_subnet.private_b.id]

  tags = {
    Name = "kiro-lab-db-subnet-group"
  }
}

resource "aws_security_group" "db_sg" {
  name        = "db-sg"
  description = "Security group for RDS database"
  vpc_id      = aws_vpc.lab.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "db-sg"
  }
}

resource "aws_db_instance" "db" {
  identifier            = "kiro-lab-db"
  engine                = "mysql"
  instance_class        = "db.t3.micro"
  allocated_storage     = 20
  username              = "admin"
  password              = "ChangeMe123!"
  skip_final_snapshot   = true
  publicly_accessible   = false
  db_subnet_group_name  = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]
}

resource "aws_s3_bucket" "assets" {
  bucket = "kiro-lab-assets-${random_id.bucket_id.hex}"
}

resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "assets" {
  depends_on = [aws_s3_bucket_ownership_controls.assets]
  bucket     = aws_s3_bucket.assets.id
  acl        = "private"
}

resource "random_id" "bucket_id" { byte_length = 4 }

resource "aws_cloudwatch_log_group" "kiro_logs" {
  name = "/kiro/lab"
  retention_in_days = 7
}
