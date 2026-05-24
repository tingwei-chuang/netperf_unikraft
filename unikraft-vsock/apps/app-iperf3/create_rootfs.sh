#!/bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [[ -e tmp ]];
then
    echo -e "${YELLOW}[NOTE]${NC} The tmp/ folder already exists. This script will ${RED}delete${NC} the tmp/ folder and all its contents."
    read -p "$(echo -e ${YELLOW}[CHECK]${NC} Are you sure you want to continue? [Y/n]:)" confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${RED}[STOP]${NC} Operation cancelled."
        exit 1
    fi
    rm -rf tmp
fi

mkdir -p tmp
find tmp | cpio -o --format newc > rootfs-iperf3.cpio
rm -rf tmp

echo -e "${GREEN}[OK]${NC} Done!"
