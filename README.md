# SQL Inventory Dashboard

A containerized PowerShell Universal Dashboard for collecting SQL Server and host OS inventory with real-time log monitoring, credential input, and CSV output display.

## 🚀 Features
- Dynamic form input for server names, credentials, and options
- Real-time log viewer
- CSV result viewer
- Dry run support
- Credential-secure operations
- Docker-based deployment
- GitHub Actions CI/CD deployment

## 📁 Repository Structure
```
├── Dockerfile
├── docker-compose.yml
├── Dashboard.ps1
├── Run-SqlInventory.ps1
├── .github
│   └── workflows
│       └── deploy.yml
```

## 🔧 Setup
### 1. Clone the Repo
```bash
git clone https://github.com/<your-username>/sql-inventory-dashboard.git
cd sql-inventory-dashboard
```

### 2. Add Required Secrets to GitHub Repo
- `DOCKER_USERNAME`
- `DOCKER_PASSWORD`
- `SERVER_HOST`
- `SERVER_USER`
- `SERVER_SSH_KEY` (Base64-encoded private key recommended)

### 3. Push to Main Branch
```bash
git add .
git commit -m "Initial deployment"
git push origin main
```

## 🐳 Local Development
```bash
docker-compose up -d --build
```
Visit `http://localhost:5000` to access the dashboard.

## 🛠 Maintainer
Tim — system admin & PowerShell enthusiast

---
*Built using PowerShell Universal by Ironman Software*
