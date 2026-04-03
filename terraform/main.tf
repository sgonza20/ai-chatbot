# Data source to get current region for AZs
data "aws_region" "current" {}

# Get the latest ECS-optimized AMI for Amazon Linux 2
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

# Define a standard /16 VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "golang-chatbot-vpc"
  }
}

variable "alb_cert_arn" {
  description = "The ARN of the ACM certificate for HTTPS termination."
  type        = string
  default     = "arn:aws:acm:us-east-1:949940714686:certificate/48e6dda0-a1f8-449d-99dc-81c740cc58d9"
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

# Public Subnet 1
resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${data.aws_region.current.name}a"
  map_public_ip_on_launch = true 

  tags = {
    Name = "golang-chatbot-public-a"
  }
}

# Public Subnet 2
resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${data.aws_region.current.name}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "golang-chatbot-public-b"
  }
}

# Route Table for Public Subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# IAM Policy Document for the Task Execution Role
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

resource "aws_iam_role_policy_attachment" "ecs_execution_role_attach" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- NEW: IAM ROLE FOR EC2 INSTANCES ---
resource "aws_iam_role" "ecs_node_role" {
  name = "golang-chatbot-ecs-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_node_role_attach" {
  role       = aws_iam_role.ecs_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_node_profile" {
  name = "golang-chatbot-ecs-node-profile"
  role = aws_iam_role.ecs_node_role.name
}

# --- ALB SECURITY GROUP ---
resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id
  name   = "golang-chatbot-alb-sg"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- TASK/NODE SECURITY GROUP ---
resource "aws_security_group" "allow_http" {
  vpc_id = aws_vpc.main.id
  name   = "golang-chatbot-sg"
  description = "Allow inbound traffic from ALB only"

  ingress {
    from_port       = 0
    to_port         = 65535 # Allow all ports from ALB for EC2 bridge/host modes
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ALB ---
resource "aws_lb" "chatbot_alb" {
  name               = "golang-chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id] 
  enable_deletion_protection = false

  tags = {
    Name = "GolangChatbotALB"
  }
}

resource "aws_lb_target_group" "chatbot_tg" {
  name        = "golang-chatbot-tg"
  port        = 8080 
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Keep "ip" because task is using awsvpc network mode

  health_check {
    path                = "/health" 
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https_listener" {
  load_balancer_arn = aws_lb.chatbot_alb.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.alb_cert_arn 

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
  }
}

# ECR Repository
resource "aws_ecr_repository" "chatbot_repo" {
  name                 = "golang-chatbot-repo"
  image_tag_mutability = "MUTABLE"
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- ECS CLUSTER ---
resource "aws_ecs_cluster" "chatbot_cluster" {
  name = "golang-chatbot-cluster"
}

# --- NEW: EC2 AUTO SCALING GROUP ---
resource "aws_launch_template" "ecs_lt" {
  name_prefix   = "ecs-template"
  image_id      = data.aws_ssm_parameter.ecs_optimized_ami.value
  instance_type = "t3.micro"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_node_profile.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.allow_http.id]
  }

  # This identifies which cluster the instance should join
  user_data = base64encode("#!/bin/bash\necho ECS_CLUSTER=${aws_ecs_cluster.chatbot_cluster.name} >> /etc/ecs/ecs.config")
}

resource "aws_autoscaling_group" "ecs_asg" {
  vpc_zone_identifier = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  desired_capacity    = 1
  max_size            = 2
  min_size            = 1

  launch_template {
    id      = aws_launch_template.ecs_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}

# --- ECS TASK DEFINITION (Modified for EC2) ---
resource "aws_ecs_task_definition" "chatbot_task" {
  family                   = "golang-chatbot-task"
  requires_compatibilities = ["EC2"] # CHANGED
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  container_definitions = jsonencode([
    {
      name      = "golang-chatbot-container"
      image     = "${aws_ecr_repository.chatbot_repo.repository_url}:latest"
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

# --- ECS SERVICE (Modified for EC2) ---
resource "aws_ecs_service" "chatbot_service" {
  name            = "golang-chatbot-service"
  cluster         = aws_ecs_cluster.chatbot_cluster.id
  task_definition = aws_ecs_task_definition.chatbot_task.arn
  desired_count   = 1
  launch_type     = "EC2" # CHANGED
  
  load_balancer {
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
    container_name   = "golang-chatbot-container" 
    container_port   = 8080                       
  }

  network_configuration {
    subnets          = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_groups  = [aws_security_group.allow_http.id] 
    assign_public_ip = false # Not required for EC2 tasks; the host has the IP
  }
}

# IAM Role for ECS Task
resource "aws_iam_role" "ecs_task_role" {
  name = "golang-chatbot-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "golang-chatbot-task-policy"
  role = aws_iam_role.ecs_task_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["sts:AssumeRole"],
        Resource = "*"
      }
    ]
  })
}

output "alb_dns_name" {
  description = "The DNS name of the Application Load Balancer"
  value       = aws_lb.chatbot_alb.dns_name
}