#!/bin/bash

Script Setup & Configuration 
set -euo pipefail 

# Variables for Logging
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

# Handling errors
log_action() {
    local type="$1" # SUCCESS, INFO, ERROR
    local message="$2"
    local exit_code="${3:-0}" # Default exit code is 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$type] $message" | tee -a "$LOG_FILE"
    if [[ "$type" == "ERROR" ]]; then
        # Ensure cleanup is performed before final exit on failure
        exit "$exit_code"
    fi
}

# Command for unexpected errors
trap 'log_action ERROR "Unexpected error occurred on line $LINENO." 1' ERR

# Collecting necessary info from User Input
log_action INFO "Starting DevOps Deployment Script..."

read -r -p "Enter Git Repository URL (e.g., https://github.com/user/repo.git): " REPO_URL
if [ -z "$REPO_URL" ]; then log_action ERROR "Git Repository URL is required." 2; fi

read -r -s -p "Enter GitHub Personal Access Token (PAT): " PAT
echo 
if [ -z "$PAT" ]; then log_action ERROR "Personal Access Token (PAT) is required." 3; fi

read -r -p "Enter Branch name (e.g., main or dev, default: main): " BRANCH_INPUT
BRANCH="${BRANCH_INPUT:-main}"

read -r -p "Remote Server Username: " SSH_USER
if [ -z "$SSH_USER" ]; then log_action ERROR "SSH Username is required." 4; fi

read -r -p "Remote Server IP address: " SSH_IP
if [ -z "$SSH_IP" ]; then log_action ERROR "Server IP address is required." 5; fi

read -r -p "Path to SSH Private Key (e.g., ~/.ssh/id_rsa): " SSH_KEY_PATH
if [ ! -f "$SSH_KEY_PATH" ]; then log_action ERROR "SSH Key path is invalid or file does not exist." 6; fi

read -r -p "Application Container Port (e.g., 8080): " APP_PORT
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then log_action ERROR "Application Port must be a number." 7; fi


REPO_NAME=$(basename "$REPO_URL" .git)
DEPLOY_DIR="/tmp/$REPO_NAME"
AUTH_REPO_URL="https://$PAT@$(echo "$REPO_URL" | sed 's/https:\/\///')"
REMOTE_PATH="/opt/deployment/$REPO_NAME"


if [[ "${1:-}" == "--cleanup" ]]; then
    log_action INFO "Starting cleanup process on $SSH_IP..."
    CLEANUP_COMMANDS=$(cat <<- EOF
        
        if [ -d "$REMOTE_PATH" ]; then
            cd $REMOTE_PATH || true
            if [ -f "docker-compose.yml" ]; then
                docker-compose down -v || true
            else
                docker stop "$REPO_NAME" || true
                docker rm "$REPO_NAME" || true
            fi
            
            rm -rf $REMOTE_PATH
        fi
   
        sudo rm -f /etc/nginx/sites-available/$REPO_NAME
        sudo rm -f /etc/nginx/sites-enabled/$REPO_NAME
        sudo systemctl reload nginx || true
        echo "Remote resources cleaned up."
EOF
)
    
    ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" "$CLEANUP_COMMANDS"
    log_action SUCCESS "Cleanup complete. Exiting."
    exit 0
fi

# Cloning the repository
log_action INFO "Stage 2: Cloning/Pulling repository locally..."

if [ -d "$DEPLOY_DIR" ]; then
    log_action INFO "Repository exists locally. Pulling latest changes."
    cd "$DEPLOY_DIR"
    git checkout "$BRANCH"
    git pull origin "$BRANCH"
else
    log_action INFO "Cloning repository: $REPO_NAME on branch $BRANCH."
    git clone --branch "$BRANCH" "$AUTH_REPO_URL" "$DEPLOY_DIR"
    cd "$DEPLOY_DIR"
fi
log_action SUCCESS "Code is up-to-date in $DEPLOY_DIR."

# Verifying the Docker file 
if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ]; then
    log_action SUCCESS "Project validated: Dockerfile or docker-compose.yml exists."
else
    log_action ERROR "Validation failed: Neither Dockerfile nor docker-compose.yml found in $DEPLOY_DIR." 8
fi

# SSH and Remote Environment Preparation 
log_action INFO "Stage 3: Preparing remote server $SSH_IP."

# Connectivity Check
log_action INFO "Testing SSH connection..."
ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=5 "$SSH_USER@$SSH_IP" exit
log_action SUCCESS "SSH connection successful."

# Remote Setup Commands 
REMOTE_SETUP_COMMANDS=$(cat <<- EOF
 
    sudo apt update -y
    sudo apt install -y docker.io docker-compose nginx

    if ! getent group docker | grep -q "\b$SSH_USER\b"; then
        sudo usermod -aG docker $SSH_USER
    fi

    sudo systemctl enable --now docker nginx

    echo "--- Versions ---"
    docker --version
    nginx -v
    echo "----------------"
EOF
)
# Execute all setup commands remotely
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" "$REMOTE_SETUP_COMMANDS"
log_action SUCCESS "Remote environment (Docker, Nginx) prepared."

# Deploy the Dockerized Application (Task 6)
log_action INFO "Stage 4: Transferring files and deploying application."

# Transfer Project Files
log_action INFO "Transferring project files via SCP to $REMOTE_PATH..."
ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" "mkdir -p $REMOTE_PATH" # Create remote directory
scp -r -i "$SSH_KEY_PATH" "$DEPLOY_DIR"/* "$SSH_USER@$SSH_IP:$REMOTE_PATH"
log_action SUCCESS "File transfer complete."

# Remote Build and Run 
REMOTE_DEPLOY_COMMANDS=$(cat <<- EOF
    cd $REMOTE_PATH

    echo "Stopping and removing old containers for safe redeployment..."
    if [ -f "docker-compose.yml" ]; then
        docker-compose down || true
        docker-compose rm -f || true
    else
        docker stop "$REPO_NAME" || true
        docker rm "$REPO_NAME" || true
    fi

    if [ -f "docker-compose.yml" ]; then
        docker-compose up -d --build
    else
        docker build -t "$REPO_NAME-image" .
        docker run -d --name "$REPO_NAME" -p 127.0.0.1:$APP_PORT:$APP_PORT "$REPO_NAME-image"
    fi

    docker ps | grep "$REPO_NAME"
    if [ $? -ne 0 ]; then echo "Container failed to start!"; exit 1; fi
EOF
)

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" "$REMOTE_DEPLOY_COMMANDS"
log_action SUCCESS "Application container deployed and running."

# Configuring Nginx as a Reverse Proxy 
log_action INFO "Stage 5: Configuring Nginx reverse proxy."

NGINX_CONFIG=$(cat <<- EOF
server {
    listen 80;
    server_name $SSH_IP;

    location / {
        
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
)

REMOTE_NGINX_SETUP=$(cat <<- EOF
    echo '$NGINX_CONFIG' | sudo tee /etc/nginx/sites-available/$REPO_NAME

    sudo ln -sf /etc/nginx/sites-available/$REPO_NAME /etc/nginx/sites-enabled/
    sudo nginx -t
    if [ $? -ne 0 ]; then
        echo "Nginx config test failed!"
        exit 1
    fi
    sudo systemctl reload nginx
EOF
)

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" "$REMOTE_NGINX_SETUP"
log_action SUCCESS "Nginx configured and reloaded."


# Validate Deployment  
log_action INFO "Stage 6: Running final deployment validation."

REMOTE_VALIDATION=$(cat <<- EOF
    # To check Docker and Nginx status
    systemctl is-active --quiet docker
    if [ $? -ne 0 ]; then echo "Docker service is not running!"; exit 1; fi
    systemctl is-active --quiet nginx
    if [ $? -ne 0 ]; then echo "Nginx service is not running!"; exit 1; fi

    # To check Nginx reverse proxy
    
    if ! curl -s -o /dev/null -w "%{http_code}" http://localhost | grep -q "200"; then
        echo "Nginx proxy check failed: Did not receive a 200 OK response."
        exit 1
    fi
    echo "All internal checks passed remotely."
EOF
)

ssh -i "$SSH_KEY_PATH" "$SSH_USER@$SSH_IP" "$REMOTE_VALIDATION"


log_action INFO "Running external reachability test on http://$SSH_IP"
if ! curl -s -o /dev/null -w "%{http_code}" "http://$SSH_IP" | grep -q "200"; then
    log_action ERROR "External reachability test failed. Check firewall/security groups." 9
fi

log_action SUCCESS "Deployment Complete! Application available at http://$SSH_IP"


echo "Deployment log saved to: $LOG_FILE"
