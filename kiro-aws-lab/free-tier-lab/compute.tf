###############################################################
# COMPUTE - EC2 (Free: 750hrs/mo t2.micro or t3.micro)
###############################################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }
}

# Key Pair
resource "aws_key_pair" "lab" {
  key_name   = "${local.name}-key"
  public_key = var.ssh_public_key
  tags       = local.tags
}

# Web Server (t2.micro - free tier)
resource "aws_instance" "web" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.web.id]
  key_name               = aws_key_pair.lab.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp2"
    volume_size           = 8 # Free: 30GB total across all EBS
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    apt update -y
    apt install -y nginx curl jq awscli
    systemctl enable nginx
    systemctl start nginx

    # Create a simple status page
    cat > /var/www/html/index.html << 'HTML'
    <!DOCTYPE html>
    <html>
    <head><title>Kiro Free Tier Lab - Web Server</title></head>
    <body style="font-family:sans-serif;background:#1a1a2e;color:#fff;padding:40px">
      <h1>🚀 Kiro Free Tier Lab</h1>
      <p>Web Server: <strong>web-server-1</strong></p>
      <p>Instance ID: $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</p>
      <p>AZ: $(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)</p>
    </body>
    </html>
    HTML

    # Install CloudWatch agent
    wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
    dpkg -i amazon-cloudwatch-agent.deb
  EOF
  )

  tags = merge(local.tags, { Name = "${local.name}-web-server", Role = "web" })
}

# App Server (t2.micro - free tier)
resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.public_b.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.lab.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp2"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    apt update -y
    apt install -y python3 python3-pip curl jq awscli
    pip3 install flask boto3

    # Simple Flask app
    cat > /home/ubuntu/app.py << 'PYEOF'
    from flask import Flask, jsonify
    import boto3, os

    app = Flask(__name__)

    @app.route('/health')
    def health():
        return jsonify({"status": "healthy", "service": "app-server"})

    @app.route('/dynamo')
    def dynamo():
        client = boto3.client('dynamodb', region_name=os.environ.get('AWS_REGION', 'ap-south-1'))
        return jsonify({"dynamodb": "connected"})

    if __name__ == '__main__':
        app.run(host='0.0.0.0', port=8080)
    PYEOF

    nohup python3 /home/ubuntu/app.py &
  EOF
  )

  tags = merge(local.tags, { Name = "${local.name}-app-server", Role = "app" })
}

# Elastic IP for Web Server (free when attached)
resource "aws_eip" "web" {
  instance = aws_instance.web.id
  domain   = "vpc"
  tags     = merge(local.tags, { Name = "${local.name}-web-eip" })
}
