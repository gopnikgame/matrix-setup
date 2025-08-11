#!/bin/bash

REPO_URL="https://github.com/gopnikgame/matrix-setup.git"
INSTALL_DIR="/opt/matrix-setup"
LINK_PATH="/usr/local/bin/manager-matrix"

sudo mkdir -p /opt
sudo git clone $REPO_URL $INSTALL_DIR

sudo chmod -R +x $INSTALL_DIR/modules/*.sh
sudo chmod +x $INSTALL_DIR/manager-matrix.sh

sudo ln -sf $INSTALL_DIR/manager-matrix.sh $LINK_PATH

echo "Matrix setup scripts installed to $INSTALL_DIR"
echo "You can now run 'sudo manager-matrix' to manage your Matrix server"