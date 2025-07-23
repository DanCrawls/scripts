#!/bin/bash

set -e

USER_NAME="$(whoami)"
GROUP_NAME="media"
HOME_DIR="/home/$USER_NAME"

echo "==> Ensuring group '$GROUP_NAME' exists and user '$USER_NAME' is a member..."
if ! getent group "$GROUP_NAME" > /dev/null; then
  sudo groupadd "$GROUP_NAME"
  echo "==> Group '$GROUP_NAME' created."
fi

if ! id -nG "$USER_NAME" | grep -qw "$GROUP_NAME"; then
  sudo usermod -aG "$GROUP_NAME" "$USER_NAME"
  echo "==> User '$USER_NAME' added to group '$GROUP_NAME'."
fi

echo "==> Updating system and installing prerequisites..."
sudo pacman -Syu --noconfirm
sudo pacman -S --needed --noconfirm wget git base-devel

echo "==> Cloning yay from the AUR..."
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
cd ..
rm -rf yay

echo "==> Installing packages with yay..."
yay -S --noconfirm \
  sabnzbd \
  jellyfin-server \
  jellyfin-web \
  navidrome \
  dotnet-runtime \
  dotnet-host \
  dotnet-sdk \
  dotnet-runtime-9.0 \
  aspnet-runtime-9.0 \
  git \
  python-pyopenssl \
  unzip \
  7zip \
  python \
  radarr-bin \
  sonarr-bin \
  jellyseerr \
  lidarr-bin \
  whisparr-bin

echo "==> Installing Jackett..."
cd /opt
f=Jackett.Binaries.LinuxAMDx64.tar.gz
sudo wget -Nc https://github.com/Jackett/Jackett/releases/latest/download/"$f"
sudo tar -xzf "$f"
sudo rm -f "$f"
cd Jackett*
sudo chown "$USER_NAME:$GROUP_NAME" -R "/opt/Jackett"
sudo ./install_service_systemd.sh
systemctl status jackett.service || true
cd -

echo -e "\n==> Jackett installed. Visit: http://127.0.0.1:9117"
echo "==> Fully overriding sabnzbd.service to set correct user/group/umask..."

# Define variables
USER_NAME="sabnzbd"        # replace with your actual username if variable already defined
GROUP_NAME="media"
SAB_CONFIG="/var/lib/sabnzbd/sabnzbd.ini"

# Make sure the config directory exists and is accessible
sudo mkdir -p /var/lib/sabnzbd
sudo chown -R "$USER_NAME:$GROUP_NAME" /var/lib/sabnzbd
sudo chmod -R 775 /var/lib/sabnzbd

# Copy original unit file to /etc/systemd/system to override fully
if [ -f /lib/systemd/system/sabnzbd.service ]; then
  echo "-> Copying original sabnzbd.service to /etc/systemd/system/"
  sudo cp /lib/systemd/system/sabnzbd.service /etc/systemd/system/sabnzbd.service
else
  echo "!! Original sabnzbd.service not found in /lib/systemd/system/. Please locate and adjust this path."
fi

# Replace relevant lines in the unit file
sudo sed -i "s|^User=.*|User=$USER_NAME|" /etc/systemd/system/sabnzbd.service
sudo sed -i "s|^Group=.*|Group=$GROUP_NAME|" /etc/systemd/system/sabnzbd.service

# Insert UMask=002 if not already present
if ! grep -q "^UMask=" /etc/systemd/system/sabnzbd.service; then
  sudo sed -i "/^\[Service\]/a UMask=002" /etc/systemd/system/sabnzbd.service
else
  sudo sed -i "s|^UMask=.*|UMask=002|" /etc/systemd/system/sabnzbd.service
fi

# Reload and restart
echo "-> Reloading systemd and restarting sabnzbd.service"
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl restart sabnzbd.service

echo "==> Starting SABnzbd briefly to generate config..."

# Wait up to 10 seconds for config to be created
for i in {1..10}; do
  if [ -f "$SAB_CONFIG" ]; then
    echo "-> Found sabnzbd.ini at $SAB_CONFIG"
    break
  fi
  echo "-> Waiting for sabnzbd.ini to be created... ($i)"
  sleep 1
done

if [ -f "$SAB_CONFIG" ]; then
  echo "-> Updating SABnzbd to listen on 0.0.0.0"
  sudo sed -i 's/^host *=.*/host = 0.0.0.0/' "$SAB_CONFIG" || \
  echo "host = 0.0.0.0" | sudo tee -a "$SAB_CONFIG"
else
  echo "!! Config file still not found after waiting — skipping host modification"
fi

sudo systemctl restart sabnzbd.service


echo "==> SABnzbd should now be running under user '$USER_NAME', group '$GROUP_NAME', with umask 002."

echo "==> SABnzbd service status:"
systemctl status sabnzbd.service --no-pager || true



echo "==> Installing Real-Debrid Client (rdtc)..."
cd "$HOME_DIR"
wget https://github.com/rogerfar/rdt-client/releases/download/v2.0.114/RealDebridClient.zip
mkdir -p rdtc && cd rdtc
mv ../RealDebridClient.zip .
unzip RealDebridClient.zip

echo "==> Creating systemd service for RdtClient..."
sudo tee /etc/systemd/system/rdtclient.service > /dev/null <<EOF
[Unit]
Description=RdtClient Service
After=network.target

[Service]
WorkingDirectory=$HOME_DIR/rdtc
ExecStart=/usr/bin/dotnet RdtClient.Web.dll
SyslogIdentifier=RdtClient
User=root
Group=$GROUP_NAME
UMask=002
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

echo "==> Reloading systemd, enabling, and starting RdtClient..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable rdtclient.service
sudo systemctl start rdtclient.service

echo "==> RdtClient service status:"
systemctl status rdtclient.service || true

echo "==> Installing yt-dlp (dependency)..."
yay -S --noconfirm yt-dlp || sudo pip install yt-dlp

echo "==> Setting up Deezer Downloader in virtualenv..."

DEEZER_DIR="/var/lib/deezerdl"
sudo python3 -m venv "$DEEZER_DIR"

sudo chown -R "$USER_NAME:$GROUP_NAME" "$DEEZER_DIR"
sudo chmod -R 775 "$DEEZER_DIR"

cd "$DEEZER_DIR" || exit
./bin/pip install --upgrade pip
./bin/pip install deezer-downloader

echo "==> Generating default config.ini for deezer-downloader..."
sudo -u "$USER_NAME" ./bin/deezer-downloader --show-config-template > config.ini

echo "Please edit '$DEEZER_DIR/config.ini' to add your ARL token and set download directories."
echo "Example: set download directory to your Lidarr root music folder, e.g. <mountpoint>/Media/Final/music"

echo "==> Creating systemd service for Deezer Downloader..."

sudo tee /etc/systemd/system/deezerdl.service > /dev/null <<EOF
[Unit]
Description=Deezer Downloader Service
After=network.target

[Service]
Type=simple
User=$USER_NAME
Group=$GROUP_NAME
WorkingDirectory=$DEEZER_DIR
ExecStart=$DEEZER_DIR/bin/deezer-downloader --config $DEEZER_DIR/config.ini
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Reloading systemd, enabling, and starting deezer-dl service..."
sudo systemctl daemon-reload
sudo systemctl enable deezerdl.service
sudo systemctl start deezerdl.service

echo "==> Deezer Downloader service status:"
systemctl status deezerdl.service || true

echo "==> Forcing Deezer Downloader web interface to listen on 0.0.0.0..."

if grep -q "^\[http\]" "$DEEZER_DIR/config.ini"; then
  # Modify host line only inside the [http] section
  sed -i '/^\[http\]/,/^\[.*\]/ s/^host *=.*/host = 0.0.0.0/' "$DEEZER_DIR/config.ini"
else
  echo -e "\n[http]\nhost = 0.0.0.0" >> "$DEEZER_DIR/config.ini"
fi

sudo systemctl restart deezerdl.service

echo "==> Configuring Navidrome..."
echo "Default media directory will be set to /dev/null. Please edit /etc/navidrome/navidrome.toml and set your own media dir."

sudo systemctl start navidrome

sudo tee /etc/navidrome/navidrome.toml > /dev/null <<EOF
# This is just an example! Please see available options to customize Navidrome for your needs at
# https://www.navidrome.org/docs/usage/configuration-options/#available-options

LogLevel = 'DEBUG'
Scanner.Schedule = '@every 24h'
TranscodingCacheSize = '150MiB'
MusicFolder = '/dev/null'
TranscodingEnabled = true
TranscodingQuality = 4  # (range 1-10, lower = better quality but larger files)
EOF

echo "==> Navidrome configuration updated."

sudo systemctl restart navidrome

echo "==> Enabling and starting all media-related services..."

SERVICES=(
  jackett.service
  rdtclient.service
  deezerdl.service
  jellyfin.service
  sabnzbd.service
  radarr.service
  sonarr.service
  lidarr.service
  jellyseerr.service
  navidrome.service
)

for service in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "$service"; then
    echo "-> Enabling and starting $service"
    sudo systemctl enable "$service"
    sudo systemctl start "$service"
  else
    echo "!! Skipping $service (not found)"
  fi
done

echo "==> All available services enabled and started!"
