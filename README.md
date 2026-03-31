# 3‑Tier Web App – Auto Scaling & CI/CD on AWS

Highly available 3‑tier web application on AWS with automated deployments and Blue/Green releases.  
Backend is an Express.js + PostgreSQL API, frontend is a React SPA, and infrastructure uses ALB + Auto Scaling Group + RDS + CodePipeline/CodeBuild/CodeDeploy.

> This project was built as part of the **“Automation, Auto Scaling & CI/CD for 3‑Tier Applications”** assignment.

---

## Architecture Overview

The application runs entirely inside a dedicated VPC:

- **Frontend**: React app served from an EC2 instance with Nginx
- **Backend**: Node/Express API in an Auto Scaling Group behind an internal Application Load Balancer
- **Database**: Amazon RDS for PostgreSQL in private subnets
- **Networking**: Public + private subnets across multiple AZs, security‑group based access
- **CI/CD**: CodePipeline → CodeBuild → CodeDeploy for backend Blue/Green deployments

<!-- TODO: replace with your actual image path -->
[![Generate-a-clear-202603311303.jpg](https://i.postimg.cc/4Nwg4g14/Generate-a-clear-202603311303.jpg)](https://postimg.cc/N5yVbZVZ)
---

## Key Features

- **3‑tier architecture**
  - React frontend, Express/Prisma backend, PostgreSQL database
- **High availability & self‑healing**
  - Backend runs in an Auto Scaling Group across multiple AZs
  - Launch template + user data fully bootstraps new instances
- **Dynamic auto scaling**
  - CPU‑based scale‑out / scale‑in policies for the backend ASG
- **Automated deployments**
  - AWS CodePipeline fetches source from GitHub
  - CodeBuild packages backend using `backend-buildspec.yml`
  - CodeDeploy deploys to ASG using `appspec.yml` and lifecycle hooks
- **Blue/Green strategy**
  - Separate blue/green target groups and listeners
  - Traffic shifted only after health checks pass
- **Parameter‑driven configuration**
  - Uses AWS Systems Manager Parameter Store for backend ALB URL and secrets
- **Idempotent, production‑style scripts**
  - Robust Bash scripts handle PM2, migrations, health checks, and retries

---

## Repository Structure

```text
backend-postgresql/
  src/               # Express API and routes
  prisma/            # Prisma schema and migrations
  scripts/
    asg-userdata.sh
    deploy-backend.sh
    codedeploy-before-install.sh
    codedeploy-deploy-backend.sh
    codedeploy-application-start.sh

react-frontend/
  src/               # React components and pages
  scripts/
    deploy-frontend.sh

appspec.yml          # CodeDeploy configuration (backend)
backend-buildspec.yml# CodeBuild configuration (backend)

```
## How to Validate the Deployment
After CodePipeline + CodeDeploy:
1. **CodeDeploy** status shows success for the backend deployment group.
2. **ALB Target Group** health checks pass for both Blue/Green as required.
3. Backend health endpoint works:
   - from an instance: `curl http://127.0.0.1:4000/api/health`
4. Frontend can call backend APIs:
   - open the app UI and verify todo CRUD works through the `/api` proxy.

## Troubleshooting Notes (Common Issues)
- `Target group not configured to receive traffic from load balancer`  
  → Green target group must be linked to a listener (e.g., HTTP:8080).
- `Target instances must be empty` during Blue/Green  
  → Ensure the green target group starts empty.
- `Health check failed` in ApplicationStart  
  → Add retry/wait logic before declaring the backend unhealthy.
- `file already exists` during Install  
  → Use `file_exists_behavior: OVERWRITE` in `appspec.yml`.
