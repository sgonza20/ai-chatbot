## 🤖 Go Chatbot Full-Stack Deployment (AWS Fargate, CloudFront, Terraform)

------------------------------------------------------------------------

### **Overview**

This repository contains the full-stack infrastructure and code for a
high-performance, real-time **AI chatbot application**.\
The frontend is built with **React**, delivered globally via **AWS
CloudFront**, and the backend is a **Golang API** deployed on **AWS
Fargate (ECS)**. The entire system is fully automated using
**Terraform** and **GitHub Actions**.

All traffic is encrypted end-to-end with **HTTPS**, ensuring secure,
reliable communication between the React UI and the Go backend hosted
at:

    https://api.samlozano.com/chat

------------------------------------------------------------------------

### **✨ Key Features**

-   **⚡ Real-time AI Chatbot:** Backend integrates directly with **AWS
    Bedrock** for low-latency inference.
-   **☁️ Fully Cloud-Native:** Deployed using AWS Fargate (serverless
    containers) with an Application Load Balancer.
-   **📦 CI/CD Ready:** Automated Docker builds + ECS deploys via GitHub
    Actions.
-   **🛡️ Secure by Default:** TLS termination at ALB, CloudFront HTTPS,
    Route 53 DNS.
-   **📈 Globally Scalable:** CloudFront CDN + horizontally scalable
    Fargate tasks.
-   **🧩 Modular IaC:** Terraform split into frontend & backend stacks
    for maintainability.

------------------------------------------------------------------------

### **🚀 Getting Started**

Follow these steps to run the project locally for development or
testing.

------------------------------------------------------------------------

#### **Prerequisites**

You will need:

-   **Go** (1.20+ recommended)
-   **Docker**
-   **AWS CLI** (configured with credentials)
-   **Terraform** (if deploying infrastructure)
-   **Git**

------------------------------------------------------------------------

### **🔧 Installation**

#### **1. Clone the repository**

``` bash
git clone https://github.com/yourusername/your-chatbot-repo.git
cd your-chatbot-repo
```

------------------------------------------------------------------------

#### **2. Environment Variables**

Create a `.env` file:

    AWS_REGION=us-east-1
    MODEL_ID=arn:aws:bedrock:us-east-1:949940714686:inference-profile/global.anthropic.claude-sonnet-4-20250514-v1:0
    PORT=8080

------------------------------------------------------------------------

#### **3. Run Locally**

``` bash
go run main.go
```

Backend should start at:

    http://localhost:8080

------------------------------------------------------------------------

### **⚙️ Architecture**

The system follows a modern, secure, two-tier deployment pattern on AWS.

------------------------------------------------------------------------

#### **📐 High-Level Architecture Diagram**

``` mermaid
graph TD

    %% Frontend
    subgraph Frontend_Static_Site["Frontend Static Site"]
        A[Browser User]
        CF[CloudFront]
        S3[S3 Bucket React Assets]
    end

    %% DNS and SSL
    subgraph Networking_DNS["AWS Networking and DNS"]
        R53[Route 53 DNS]
        ACM[ACM SSL Certificate]
    end

    %% Backend
    subgraph Backend_Go_API["AWS Backend Go API Fargate"]
        ALB[Application Load Balancer HTTPS to HTTP]
        ECSC[ECS Fargate Service]
        TD[ECS Task Definition]
        ECR[ECR Repository]
        Bedrock[AWS Bedrock]
        VPC[VPC and Subnets]
        CW[CloudWatch Logs]
    end

    %% Relationships
    A -->|Access UI HTTPS| CF
    CF --> S3
    S3 --> A
    
    A -->|API Request| R53
    R53 -->|Alias Record| ALB
    ALB -->|Routes Traffic| ECSC
    ECSC -->|Invoke Model| Bedrock
    Bedrock -->|Response| A

    TD --> ECR
    ECSC --> CW
    ECSC --> VPC
    ACM -->|Used by| ALB
```

------------------------------------------------------------------------

### **🧩 Core Components**

  -------------------------------------------------------------------------------
  Component              AWS Service                        Role
  ---------------------- ---------------------------------- ---------------------
  **Frontend Hosting**   S3 + CloudFront                    Serves global React
                                                            application over
                                                            HTTPS

  **Backend Compute**    ECS Fargate                        Runs the Golang
                                                            chatbot application

  **Load Balancing**     Application Load Balancer          HTTPS termination +
                                                            routing to Fargate
                                                            tasks

  **AI Model**           AWS Bedrock                        Handles natural
                                                            language inference

  **Container Registry** Amazon ECR                         Stores Docker images

  **Network Layer**      VPC & Subnets                      Secure private
                                                            networking

  **IAM Roles**          IAM                                Grants ECS tasks
                                                            access to Bedrock &
                                                            CloudWatch

  **DNS**                Route 53                           Routes
                                                            `api.samlozano.com` →
                                                            ALB
  -------------------------------------------------------------------------------

------------------------------------------------------------------------

### **📜 Usage & Endpoints**

  --------------------------------------------------------------------------
  Method      Endpoint         Description          Example Body
  ----------- ---------------- -------------------- ------------------------
  **POST**    `/chat`          Sends a message to   `{"message": "Hello"}`
                               the chatbot          

  **GET**     `/health`        Health check         N/A
  --------------------------------------------------------------------------

------------------------------------------------------------------------

### **💬 Example Request**

``` bash
curl -X POST https://api.samlozano.com/chat      -H "Content-Type: application/json"      -d '{"message": "Hello"}'
```

------------------------------------------------------------------------

### **🧪 Local Testing (Docker)**

``` bash
docker run   -e MODEL_ID="arn:aws:bedrock:us-east-1:949940714686:inference-profile/global.anthropic.claude-sonnet-4-20250514-v1:0"   -e AWS_PROFILE=sam   -e AWS_REGION=us-east-1   -v ~/.aws:/root/.aws:ro   -p 8080:8080   bedrock-bot:latest
```

Then:

``` bash
curl -X POST http://localhost:8080/chat      -H "Content-Type: application/json"      -d '{"message":""}'
```

------------------------------------------------------------------------

### **🤝 Contributing**

1.  Fork the repo\
2.  Create a feature branch\
3.  Commit changes\
4.  Push your branch\
5.  Open a Pull Request

------------------------------------------------------------------------

### **📄 License**

Distributed under the **MIT License**.

------------------------------------------------------------------------

### **📞 Contact**

Sam Lozano\
Project Link: https://github.com/yourusername/your-chatbot-repo
