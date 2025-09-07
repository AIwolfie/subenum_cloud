#!/bin/bash

# Install dependencies for Telegram Subdomain Bot

set -e

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 1>&2
   exit 1
fi

# Update package lists
apt-get update

# Install core utilities
apt-get install -y curl jq zip

# Install Go (required for subfinder, httpx-toolkit, etc.)
if ! command -v go &>/dev/null; then
    echo "Installing Go..."
    wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
    tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    export PATH=$PATH:/usr/local/go/bin
    rm go1.21.0.linux-amd64.tar.gz
fi

# Install subfinder
if ! command -v subfinder &>/dev/null; then
    echo "Installing subfinder..."
    go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
    mv ~/go/bin/subfinder /usr/local/bin/
fi

# Install assetfinder
if ! command -v assetfinder &>/dev/null; then
    echo "Installing assetfinder..."
    go install github.com/tomnomnom/assetfinder@latest
    mv ~/go/bin/assetfinder /usr/local/bin/
fi

# Install amass
if ! command -v amass &>/dev/null; then
    echo "Installing amass..."
    go install github.com/OWASP/Amass/v3/...@master
    mv ~/go/bin/amass /usr/local/bin/
fi

# Install alterx
if ! command -v alterx &>/dev/null; then
    echo "Installing alterx..."
    go install github.com/projectdiscovery/alterx/cmd/alterx@latest
    mv ~/go/bin/alterx /usr/local/bin/
fi

# Install dnsx
if ! command -v dnsx &>/dev/null; then
    echo "Installing dnsx..."
    go install github.com/projectdiscovery/dnsx/cmd/dnsx@latest
    mv ~/go/bin/dnsx /usr/local/bin/
fi

# Install httpx-toolkit
if ! command -v httpx &>/dev/null; then
    echo "Installing httpx..."
    go install github.com/projectdiscovery/httpx/cmd/httpx@latest
    mv ~/go/bin/httpx /usr/local/bin/
fi

# Install github-subdomains
if ! command -v github-subdomains &>/dev/null; then
    echo "Installing github-subdomains..."
    go install github.com/gwen001/github-subdomains@latest
    mv ~/go/bin/github-subdomains /usr/local/bin/
fi

# Install seclists (for alterx wordlist)
if [[ ! -d /usr/share/seclists ]]; then
	echo "Installing seclists..."
	apt-get install -y seclists
fi

if ! command -v nuclei &>/dev/null; then
	echo "Installing nuclei..."
	go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
	mv ~/go/bin/nuclei /usr/local/bin
	
echo "All dependencies installed successfully!"
