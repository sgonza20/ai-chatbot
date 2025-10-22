# Define a standard /16 VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "golang-chatbot-vpc"
  }
}

resource "aws_cloudwatch_log_group" "chatbot" {
  name              = "/ecs/golang-chatbot"
  retention_in_days = 7
}

resource "aws_iam_policy" "cw_logs_policy" {
  name = "ECSCloudWatchLogsPolicy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:log-group:/ecs/golang-chatbot:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_exec_attach_cw" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = aws_iam_policy.cw_logs_policy.arn
}

# Internet Gateway for public access
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "golang-chatbot-igw"
  }
}

# Public Subnet 1 (us-west-2a, for example)
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = true # Fargate needs a public IP for internet access

  tags = {
    Name = "golang-chatbot-public-a"
  }
}

# Public Subnet 2 (us-west-2b, for example)
resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${data.aws_region.current.name}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "golang-chatbot-public-b"
  }
}

# Route Table for Public Subnets (directs traffic to IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

# Associate Route Table with Subnets
resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# Data source to get current region for AZs
data "aws_region" "current" {}

# Output the subnet IDs for use in the ECS service
output "public_subnet_ids" {
  value = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

# IAM Policy Document for the Task Execution Role trust relationship
data "aws_iam_policy_document" "ecs_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ECS Task Execution Role
resource "aws_iam_role" "ecs_execution_role" {
  name               = "golang-chatbot-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role_policy.json
}

# Attach the standard AWS-managed policy for task execution
resource "aws_iam_role_policy_attachment" "ecs_execution_role_attach" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Security Group to allow inbound traffic on the Go application's port
resource "aws_security_group" "allow_http" {
  vpc_id = aws_vpc.main.id
  name   = "golang-chatbot-sg"
  description = "Allow inbound traffic on the chatbot port"

  # Inbound rule: Allow TCP traffic on port 8080 from the internet
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound rule: Allow all outbound traffic (default)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 1. ECR Repository
resource "aws_ecr_repository" "chatbot_repo" {
  name                 = "golang-chatbot-repo"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "ecr_repository_url" {
  description = "The URL of the ECR repository"
  value       = aws_ecr_repository.chatbot_repo.repository_url
}

# 2. ECS Cluster
resource "aws_ecs_cluster" "chatbot_cluster" {
  name = "golang-chatbot-cluster"
}

# 3. ECS Task Definition
resource "aws_ecs_task_definition" "chatbot_task" {
  family                   = "golang-chatbot-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  container_definitions = jsonencode([
    {
      name      = "golang-chatbot-container"
      image     = "${aws_ecr_repository.chatbot_repo.repository_url}:latest" # Initial placeholder
      cpu       = 256
      memory    = 512
      essential = true
      environment = [
        {
          name  = "MODEL_ID"
          value = "arn:aws:bedrock:us-east-1:949940714686:inference-profile/global.anthropic.claude-sonnet-4-20250514-v1:0"
        },
        {
          name  = "AWS_REGION"
          value = "us-east-1"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
            "awslogs-group"         = "/ecs/golang-chatbot"
            "awslogs-region"        = "us-east-1"
            "awslogs-stream-prefix" = "golang-chatbot"
        }
      }
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
    }
  ])
}

# 4. ECS Service (Fargate)
resource "aws_ecs_service" "chatbot_service" {
  name            = "golang-chatbot-service"
  cluster         = aws_ecs_cluster.chatbot_cluster.id
  task_definition = aws_ecs_task_definition.chatbot_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  
  # Use the VPC Subnets and Security Group defined above
  network_configuration {
    # Use the public subnet IDs defined in section 1
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    # Use the security group defined in section 3
    security_groups  = [aws_security_group.allow_http.id]
    assign_public_ip = true
  }
}

# IAM Role for ECS Task (application permissions)
resource "aws_iam_role" "ecs_task_role" {
  name = "golang-chatbot-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Policy: Allow calling Bedrock models
resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "golang-chatbot-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "sts:AssumeRole"
        ],
        Resource = "*"
      }
    ]
  })
}
