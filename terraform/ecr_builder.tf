resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-repo"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Zip the source code
data "archive_file" "source" {
  type        = "zip"
  source_dir  = "${path.module}/../docker"
  output_path = "${path.module}/source.zip"
}

resource "aws_s3_bucket" "build_source" {
  bucket        = "${var.project_name}-build-source-${random_string.suffix.result}"
  force_destroy = true
}

resource "aws_s3_object" "source" {
  bucket = aws_s3_bucket.build_source.id
  key    = "source.zip"
  source = data.archive_file.source.output_path
  etag   = data.archive_file.source.output_md5
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_security_group" "builder" {
  name        = "${var.project_name}-builder-sg"
  description = "Security group for builder instance"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "builder" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_a.id
  iam_instance_profile        = aws_iam_instance_profile.builder_profile.name
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.builder.id]

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y docker unzip
    systemctl start docker
    systemctl enable docker

    usermod -a -G docker ec2-user

    aws s3 cp s3://${aws_s3_bucket.build_source.id}/source.zip /tmp/source.zip
    cd /tmp
    unzip source.zip -d /tmp/source
    cd /tmp/source

    aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com

    docker build -t ${aws_ecr_repository.app.repository_url}:latest .
    docker push ${aws_ecr_repository.app.repository_url}:latest
  EOF

  tags = {
    Name = "${var.project_name}-builder"
  }

  depends_on = [
    aws_s3_object.source,
    aws_iam_role_policy.builder_policy
  ]
}

resource "terraform_data" "wait_for_image" {
  triggers_replace = {
    source_hash = data.archive_file.source.output_md5
    instance_id = aws_instance.builder.id
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<EOF
$ErrorActionPreference = 'Stop'
Write-Host "Waiting for EC2 builder to build and push image..."
$maxAttempts = 30
$attempt = 0
$imageFound = $false

while (-not $imageFound -and $attempt -lt $maxAttempts) {
    Start-Sleep -Seconds 20
    $attempt++
    Write-Host "Checking ECR for latest image (Attempt $attempt of $maxAttempts)..."
    
    try {
        $result = aws ecr describe-images --repository-name ${aws_ecr_repository.app.name} --image-ids imageTag=latest --region ${var.region} 2>&1
        if ($result -match "imageDigest") {
            $imageFound = $true
            Write-Host "Image found in ECR!"
        }
    } catch {
        # Ignore errors, image might not exist yet
    }
}

if (-not $imageFound) {
    Write-Error "Image was not pushed to ECR in time. Builder EC2 might have failed."
    exit 1
}
EOF
  }

  depends_on = [aws_instance.builder]
}
