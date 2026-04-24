#!/bin/sh
set -e

echo "🔧 Installing system dependencies..."
apk add --no-cache tmux dos2unix

echo "🔧 Installing Overmind..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    OVERMIND_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    OVERMIND_ARCH="arm64"
else
    OVERMIND_ARCH="amd64"
fi

wget -O overmind.gz "https://github.com/DarthSim/overmind/releases/download/v2.4.0/overmind-v2.4.0-linux-${OVERMIND_ARCH}.gz"
gunzip overmind.gz
chmod +x overmind
mv overmind /usr/local/bin/

echo "✅ Dependencies installed"

echo "🔧 Configuring isolated gem environment..."
# Force use of gems from the Docker image only
export BUNDLE_PATH=/gems
export GEM_HOME=/gems
export GEM_PATH=/gems
export PATH=/gems/bin:/usr/local/bundle/bin:$PATH

# Remove any local bundle config that might interfere
rm -f .bundle/config 2>/dev/null || true

# Set bundle to use only the image gems
bundle config set --local path '/gems'
bundle config set --local deployment false
bundle config set --local frozen false

echo "Current gem environment:"
bundle config
gem env

echo "🔄 Converting line endings for Windows compatibility..."
# Fix line endings for all critical files
dos2unix ./Procfile.dev 2>/dev/null || true
dos2unix ./package.json 2>/dev/null || true
dos2unix ./Gemfile 2>/dev/null || true
dos2unix ./config.ru 2>/dev/null || true
dos2unix ./Rakefile 2>/dev/null || true

# Fix all files in bin directory
if [ -d ./bin ]; then
    for file in ./bin/*; do
        if [ -f "$file" ]; then
            dos2unix "$file" 2>/dev/null || true
            chmod +x "$file" 2>/dev/null || true
        fi
    done
fi

# Make sure Ruby scripts are executable
chmod +x ./bin/rails 2>/dev/null || true
chmod +x ./bin/rake 2>/dev/null || true
chmod +x ./bin/bundle 2>/dev/null || true
chmod +x ./bin/vite 2>/dev/null || true

echo "📝 Creating Procfile for Docker environment..."
# Create a modified Procfile without dotenv command
# Using bundle exec to ensure we use the right gems
cat > ./Procfile.dev.docker <<EOF
backend: bundle exec rails s -p 3000 -b 0.0.0.0
worker: bundle exec sidekiq -C config/sidekiq.yml
vite: bundle exec vite dev
EOF

echo "🗄️ Preparing database..."
# db:evolution_prepare handles create + schema:load (on empty DB) + migrate (always).
# Do NOT redirect stderr or mask failures — a broken migration must stop the boot
# instead of leaving the database in a half-migrated state.
bundle exec rails db:evolution_prepare

echo "🧹 Cleaning up..."
rm -f ./.overmind.sock
rm -f ./tmp/pids/server.pid

echo "🚀 Starting services..."
exec overmind start -f ./Procfile.dev.docker
