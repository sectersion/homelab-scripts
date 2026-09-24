#!/bin/bash
set -e

# Nginx Proxy Manager installer for Proxmox LXC / Docker
# Usage: bash install-npm.sh [--host IP] [--port 81] [--db-port 3306]

NPM_HOST="${NPM_HOST:-0.0.0.0}"
NPM_PORT="${NPM_PORT:-81}"
DB_PORT="${DB_PORT:-3306}"
DATA_DIR="${DATA_DIR:-/opt/npm}"
INSTALL_METHOD="${INSTALL_METHOD:-docker}"  # docker or native

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --host)
      NPM_HOST="$2"
      shift 2
      ;;
    --port)
      NPM_PORT="$2"
      shift 2
      ;;
    --db-port)
      DB_PORT="$2"
      shift 2
      ;;
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --native)
      INSTALL_METHOD="native"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "════════════════════════════════════════════════════════"
echo "Nginx Proxy Manager Installer"
echo "════════════════════════════════════════════════════════"
echo "Method:    $INSTALL_METHOD"
echo "Host:      $NPM_HOST"
echo "Web Port:  $NPM_PORT"
echo "Data Dir:  $DATA_DIR"
echo ""

# Detect OS
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS=$ID
else
  echo "❌ Unable to detect OS"
  exit 1
fi

echo "📦 Detected OS: $OS"

# ============================================================================
# DOCKER INSTALL (Recommended for Proxmox LXC)
# ============================================================================
if [ "$INSTALL_METHOD" = "docker" ]; then
  echo ""
  echo "🐳 Installing via Docker Compose..."
  
  # Install Docker if not present
  if ! command -v docker &> /dev/null; then
    echo "📥 Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    bash get-docker.sh
    rm get-docker.sh
    
    # Add current user to docker group (if not root)
    if [ "$EUID" -ne 0 ]; then
      usermod -aG docker $USER
      echo "⚠️  Added $USER to docker group. Run 'newgrp docker' or restart shell."
    fi
  fi
  
  # Install docker-compose if not present
  if ! command -v docker-compose &> /dev/null; then
    echo "📥 Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
  fi
  
  # Create data directories
  echo "📂 Setting up directories..."
  mkdir -p "$DATA_DIR"/{data,letsencrypt}
  
  # Create docker-compose.yml
  cat > "$DATA_DIR/docker-compose.yml" <<'EOF'
version: '3.8'

services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - "${NPM_HOST:-0.0.0.0}:80:80"       # HTTP
      - "${NPM_HOST:-0.0.0.0}:443:443"     # HTTPS
      - "${NPM_HOST:-0.0.0.0}:${NPM_PORT:-81}:81"  # Admin UI
    environment:
      DB_MYSQL_HOST: db
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: npm
      DB_MYSQL_PASSWORD: ${DB_PASSWORD:-npm_password_change_me}
      DB_MYSQL_NAME: npm
      DISABLE_IPV6: 'true'
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    depends_on:
      - db
    networks:
      - npm-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/api/v2/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  db:
    image: mysql:8-alpine
    container_name: nginx-proxy-manager-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD:-root_password_change_me}
      MYSQL_DATABASE: npm
      MYSQL_USER: npm
      MYSQL_PASSWORD: ${DB_PASSWORD:-npm_password_change_me}
    volumes:
      - ./data/mysql:/var/lib/mysql
    ports:
      - "127.0.0.1:${DB_PORT:-3306}:3306"
    networks:
      - npm-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 3

networks:
  npm-network:
    driver: bridge
EOF

  # Create .env file with secure defaults
  cat > "$DATA_DIR/.env" <<EOF
NPM_HOST=${NPM_HOST}
NPM_PORT=${NPM_PORT}
DB_PORT=${DB_PORT}
DB_PASSWORD=$(openssl rand -base64 16)
DB_ROOT_PASSWORD=$(openssl rand -base64 16)
EOF

  echo "✅ Docker Compose file created at $DATA_DIR/docker-compose.yml"
  echo ""
  echo "🚀 Starting NPM containers..."
  cd "$DATA_DIR"
  docker-compose up -d
  
  echo ""
  echo "⏳ Waiting for services to be ready (30-40 seconds)..."
  sleep 40
  
  # Verify
  if docker-compose ps | grep -q "nginx-proxy-manager.*Up"; then
    echo "✅ Nginx Proxy Manager is running!"
  else
    echo "⚠️  Container may still be starting. Check with: docker-compose ps"
  fi

# ============================================================================
# NATIVE INSTALL (Ubuntu/Debian)
# ============================================================================
elif [ "$INSTALL_METHOD" = "native" ]; then
  echo ""
  echo "📦 Installing via native Debian packages..."
  
  if [ "$OS" != "debian" ] && [ "$OS" != "ubuntu" ]; then
    echo "❌ Native install only supports Debian/Ubuntu. Use --docker flag for other systems."
    exit 1
  fi
  
  # Update repos
  apt-get update
  apt-get install -y \
    curl \
    wget \
    gnupg2 \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    nodejs \
    npm \
    mysql-server \
    nginx
  
  # Create data directories
  mkdir -p "$DATA_DIR"/{data,letsencrypt}
  
  # Create npm user
  useradd -m -s /bin/false npm || true
  
  # Install npm via npm registry
  echo "📥 Installing Nginx Proxy Manager from npm..."
  mkdir -p /opt/npm-app
  cd /opt/npm-app
  npm install --production @nginx-proxy-manager/core
  
  # Setup systemd service
  cat > /etc/systemd/system/nginx-proxy-manager.service <<EOF
[Unit]
Description=Nginx Proxy Manager
After=network.target mysql.service
Wants=mysql.service

[Service]
Type=simple
User=npm
WorkingDirectory=$DATA_DIR
EnvironmentFile=$DATA_DIR/.env
ExecStart=/usr/bin/npm start --prefix /opt/npm-app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  # Create .env for native install
  cat > "$DATA_DIR/.env" <<EOF
PORT=${NPM_PORT}
DB_HOST=localhost
DB_USER=npm
DB_PASSWORD=$(openssl rand -base64 16)
DB_NAME=npm
NODE_ENV=production
EOF

  # Setup MySQL
  echo "🗄️  Setting up MySQL database..."
  DB_PASS=$(grep DB_PASSWORD "$DATA_DIR/.env" | cut -d= -f2)
  mysql -u root <<MYSQL_EOF
CREATE DATABASE IF NOT EXISTS npm;
CREATE USER IF NOT EXISTS 'npm'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON npm.* TO 'npm'@'localhost';
FLUSH PRIVILEGES;
MYSQL_EOF

  # Start service
  systemctl daemon-reload
  systemctl enable nginx-proxy-manager
  systemctl start nginx-proxy-manager
  
  echo "✅ Native install complete"

fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "════════════════════════════════════════════════════════"
echo "✅ Installation Complete!"
echo "════════════════════════════════════════════════════════"
echo ""
echo "🌐 Access Nginx Proxy Manager:"
echo "   URL: http://localhost:${NPM_PORT}"
echo "   Default credentials: admin@example.com / changeme"
echo ""
echo "📂 Data persisted at: $DATA_DIR"
echo ""
echo "📝 Next steps:"
echo "   1. Open http://localhost:${NPM_PORT} in your browser"
echo "   2. Login with admin@example.com / changeme"
echo "   3. Change your password immediately"
echo "   4. Add proxy hosts for your services"
echo ""
if [ "$INSTALL_METHOD" = "docker" ]; then
  echo "🐳 Docker commands:"
  echo "   View logs:    cd $DATA_DIR && docker-compose logs -f npm"
  echo "   Restart:      cd $DATA_DIR && docker-compose restart"
  echo "   Stop:         cd $DATA_DIR && docker-compose down"
  echo "   Update:       cd $DATA_DIR && docker-compose pull && docker-compose up -d"
  echo ""
  echo "⚠️  Change DB passwords in $DATA_DIR/.env before production!"
elif [ "$INSTALL_METHOD" = "native" ]; then
  echo "🔧 Service commands:"
  echo "   View logs:    journalctl -fu nginx-proxy-manager"
  echo "   Restart:      systemctl restart nginx-proxy-manager"
  echo "   Status:       systemctl status nginx-proxy-manager"
fi
echo ""
