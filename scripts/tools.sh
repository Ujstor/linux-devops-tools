#!/bin/bash

# Enhanced System Setup Script
# Installs Brave Browser, GitHub CLI, Azure CLI, Go tools, Python packages, npm packages, and Rust tools with proper error handling
set -euo pipefail  # Exit on error, undefined vars, pipe failures

if [[ -f "$HOME/.bashrc" ]]; then
    set +e  # Temporarily disable exit on error
    source "$HOME/.bashrc" 2>/dev/null || true
    set -e  # Re-enable exit on error
fi

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error_exit "This script should not be run as root. Please run as a regular user with sudo privileges."
    fi
}

# Check sudo privileges
check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo privileges. You may be prompted for your password."
        sudo -v || error_exit "Failed to obtain sudo privileges"
    fi
}

# Update system packages
update_system() {
    log_info "Updating system packages..."
    if ! sudo nala update && sudo nala upgrade -y; then
        error_exit "Failed to update system packages"
    fi
    log_success "System packages updated"
}

# Install base dependencies
install_base_deps() {
    log_info "Installing base dependencies..."
    local deps="software-properties-common apt-transport-https curl ca-certificates build-essential gnupg lsb-release"
    if ! sudo nala install $deps -y; then
        error_exit "Failed to install base dependencies"
    fi
    log_success "Base dependencies installed"
}

# Install Brave Browser
install_brave() {
    log_info "Installing Brave Browser..."

    # Download and add GPG key
    if ! wget -qO- https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg | \
         sudo gpg --dearmor | \
         sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg > /dev/null; then
        error_exit "Failed to add Brave GPG key"
    fi

    # Add repository
    local repo_line="deb [arch=amd64 signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main"
    if ! echo "$repo_line" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list > /dev/null; then
        error_exit "Failed to add Brave repository"
    fi

    # Update and install
    if ! sudo nala update || ! sudo nala install brave-browser -y; then
        error_exit "Failed to install Brave Browser"
    fi

    log_success "Brave Browser installed"
}

# Install GitHub CLI
install_github_cli() {
    log_info "Installing GitHub CLI..."

    # Ensure curl is available
    if ! command -v curl &> /dev/null; then
        log_info "Installing curl..."
        if ! sudo nala update && sudo nala install curl -y; then
            error_exit "Failed to install curl"
        fi
    fi

    # Add GitHub CLI repository and install
    if ! curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
         sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
         sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg; then
        error_exit "Failed to add GitHub CLI GPG key"
    fi

    local repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
    if ! echo "$repo_line" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null; then
        error_exit "Failed to add GitHub CLI repository"
    fi

    if ! sudo nala update || ! sudo nala install gh -y; then
        error_exit "Failed to install GitHub CLI"
    fi

    log_success "GitHub CLI installed"
}

# Install Azure CLI
install_azure_cli() {
    log_info "Installing Azure CLI..."

    # Check if azure-cli is already installed from universe repository (outdated version)
    if dpkg -l | grep -q "azure-cli.*2\.0\.81"; then
        log_warning "Found outdated Azure CLI package (2.0.81) from universe repository. Removing it..."
        if ! sudo apt remove azure-cli -y && sudo apt autoremove -y; then
            log_error "Failed to remove outdated Azure CLI package"
        else
            log_success "Outdated Azure CLI package removed"
        fi
    fi

    # Install packages needed for the installation process
    local deps="apt-transport-https ca-certificates curl gnupg lsb-release"
    if ! sudo nala install $deps -y; then
        error_exit "Failed to install Azure CLI dependencies"
    fi

    # Create keyrings directory if it doesn't exist
    sudo mkdir -p /etc/apt/keyrings

    # Download and install the Microsoft signing key
    if ! curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
         gpg --dearmor | \
         sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null; then
        error_exit "Failed to add Microsoft GPG key"
    fi

    sudo chmod go+r /etc/apt/keyrings/microsoft.gpg

    # Add the Azure CLI software repository
    local az_dist
    az_dist=$(lsb_release -cs)
    local repo_content="Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${az_dist}
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg"

    if ! echo "$repo_content" | sudo tee /etc/apt/sources.list.d/azure-cli.sources > /dev/null; then
        error_exit "Failed to add Azure CLI repository"
    fi

    # Update repository information and install the azure-cli package
    if ! sudo nala update || ! sudo nala install azure-cli -y; then
        error_exit "Failed to install Azure CLI"
    fi

    log_success "Azure CLI installed successfully"

    # Display version information
    local az_version
    az_version=$(az version --output json 2>/dev/null | grep '"azure-cli":' | cut -d'"' -f4 || echo "unknown")
    log_info "Azure CLI version: $az_version"
}

# Check and validate Rust installation
check_rust() {
    log_info "Checking Rust installation..."

    # Source cargo environment if it exists
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi

    # Check if cargo is available in PATH for current user
    if command -v cargo &> /dev/null; then
        local rust_version
        rust_version=$(rustc --version 2>/dev/null || echo "unknown")
        local cargo_version
        cargo_version=$(cargo --version 2>/dev/null || echo "unknown")
        log_success "Rust is installed: $rust_version"
        log_success "Cargo is installed: $cargo_version"
        return 0
    else
        log_error "Rust/Cargo is not installed or not in PATH for user $USER."
        return 1
    fi
}

# Install Rust using rustup
install_rust() {
    log_info "Installing Rust using rustup..."

    # Download and run rustup installer
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y; then
        error_exit "Failed to install Rust"
    fi

    # Source cargo environment
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi

    # Add to bashrc if not already present
    local cargo_env_line='source "$HOME/.cargo/env"'
    if ! grep -Fxq "$cargo_env_line" "$HOME/.bashrc" 2>/dev/null; then
        echo "" >> "$HOME/.bashrc"
        echo "# Rust/Cargo environment" >> "$HOME/.bashrc"
        echo "$cargo_env_line" >> "$HOME/.bashrc"
        log_info "Added Cargo environment to ~/.bashrc"
    fi

    log_success "Rust installed successfully"
}

# Install Rust packages with cargo
install_cargo_packages() {
    log_info "Installing Rust packages with cargo..."

    # Ensure cargo is available
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi

    local packages=(
        "eza"
    )

    for package in "${packages[@]}"; do
        log_info "Installing $package..."
        if ! cargo install "$package"; then
            log_error "Failed to install $package"
            continue
        fi
        log_success "$package installed"
    done

    # Ensure cargo bin is in PATH
    local cargo_bin="$HOME/.cargo/bin"
    if [[ ":$PATH:" != *":$cargo_bin:"* ]]; then
        log_warning "Adding $cargo_bin to PATH for current session"
        export PATH="$cargo_bin:$PATH"
    fi
}

# Check and validate Go installation
check_go() {
    log_info "Checking Go installation..."

    # Check if go is available in PATH for current user
    if command -v go &> /dev/null; then
        local go_version
        go_version=$(go version 2>/dev/null || echo "unknown")
        log_success "Go is installed: $go_version"
        return 0
    else
        log_error "Go is not installed or not in PATH for user $USER."
        log_info "Please install Go from: https://golang.org/doc/install"
        log_info "Or use your package manager: sudo nala install golang-go"
        log_info "Make sure to add Go to your PATH in ~/.bashrc or ~/.profile"
        return 1
    fi
}

# Install Go tools
install_go_tools() {
    log_info "Installing Go tools..."

    local tools=(
        "github.com/hetznercloud/cli/cmd/hcloud@latest"
        "github.com/dundee/gdu@latest"
        "github.com/melkeydev/go-blueprint@latest"
        "github.com/norwoodj/helm-docs/cmd/helm-docs@latest"
        "github.com/Azure/kubelogin@latest"
    )

    for tool in "${tools[@]}"; do
        local tool_name
        tool_name=$(basename "$(echo "$tool" | cut -d'@' -f1)")
        log_info "Installing $tool_name..."
        if ! go install "$tool"; then
            log_error "Failed to install $tool_name"
            continue
        fi
        log_success "$tool_name installed"
    done
}

# Check and validate Python/pip installation
check_python() {
    log_info "Checking Python and pip installation..."

    if ! command -v python3 &> /dev/null; then
        log_error "Python3 is not installed"
        return 1
    fi

    if ! command -v pip3 &> /dev/null; then
        log_error "pip3 is not installed"
        return 1
    fi

    local python_version
    python_version=$(python3 --version 2>/dev/null || echo "unknown")
    local pip_version
    pip_version=$(pip3 --version 2>/dev/null || echo "unknown")
    log_success "Python is installed: $python_version"
    log_success "pip is installed: $pip_version"
    return 0
}

# Install Python packages with pip
install_pip_packages() {
    log_info "Installing Python packages with pip..."

    local packages=(
        "ansible"
    )

    for package in "${packages[@]}"; do
        log_info "Installing $package..."
        if ! pip3 install --user "$package"; then
            log_error "Failed to install $package"
            continue
        fi
        log_success "$package installed"
    done

    # Ensure user's local bin is in PATH
    local user_bin="$HOME/.local/bin"
    if [[ ":$PATH:" != *":$user_bin:"* ]]; then
        log_warning "Adding $user_bin to PATH for current session"
        export PATH="$user_bin:$PATH"
        # Add to bashrc for future sessions
        if ! grep -q "$user_bin" "$HOME/.bashrc"; then
            echo "export PATH=\"$user_bin:\$PATH\"" >> "$HOME/.bashrc"
            log_info "Added $user_bin to ~/.bashrc for future sessions"
        fi
    fi
}

# Check and validate Node.js/npm installation
check_nodejs() {
    log_info "Checking Node.js and npm installation..."

    if ! command -v node &> /dev/null; then
        log_error "Node.js is not installed"
        return 1
    fi

    if ! command -v npm &> /dev/null; then
        log_error "npm is not installed"
        return 1
    fi

    local node_version
    node_version=$(node --version 2>/dev/null || echo "unknown")
    local npm_version
    npm_version=$(npm --version 2>/dev/null || echo "unknown")
    log_success "Node.js is installed: $node_version"
    log_success "npm is installed: $npm_version"
    return 0
}

# Install npm packages globally
install_npm_packages() {
    log_info "Installing npm packages globally..."

    local packages=(
        "@anthropic-ai/claude-code"
    )

    for package in "${packages[@]}"; do
        log_info "Installing $package..."
        # Try global install first
        if npm install -g "$package" 2>/dev/null; then
            log_success "$package installed globally"
            continue
        fi

        # If global install fails, try with sudo
        log_warning "Global install failed due to permissions, trying with sudo..."
        if sudo npm install -g "$package"; then
            log_success "$package installed globally with sudo"
            continue
        fi

        # If both fail, suggest alternative
        log_error "Failed to install $package globally"
        log_info "Alternative: You can install it locally with 'npx $package' or fix npm permissions"
        log_info "To fix npm permissions, run: sudo chown -R \$(whoami) /usr/local/lib/node_modules"
    done

    # Check if global npm bin is in PATH
    local npm_bin
    npm_bin=$(npm bin -g 2>/dev/null)
    if [[ -n "$npm_bin" ]] && [[ ":$PATH:" != *":$npm_bin:"* ]]; then
        log_warning "Global npm bin directory ($npm_bin) is not in PATH"
        log_info "You may need to add it to your PATH in ~/.bashrc"
    fi
}

# Display summary
show_summary() {
    log_info "Installation Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check installed software
    command -v brave-browser &> /dev/null && echo -e "${GREEN}[OK]${NC} Brave Browser" || echo -e "${RED}[MISSING]${NC} Brave Browser"
    command -v gh &> /dev/null && echo -e "${GREEN}[OK]${NC} GitHub CLI" || echo -e "${RED}[MISSING]${NC} GitHub CLI"
    command -v az &> /dev/null && echo -e "${GREEN}[OK]${NC} Azure CLI" || echo -e "${RED}[MISSING]${NC} Azure CLI"

    # Check Rust/Cargo
    if [[ -f "$HOME/.cargo/env" ]]; then
        source "$HOME/.cargo/env"
    fi
    command -v cargo &> /dev/null && echo -e "${GREEN}[OK]${NC} Rust/Cargo" || echo -e "${RED}[MISSING]${NC} Rust/Cargo"
    command -v go &> /dev/null && echo -e "${GREEN}[OK]${NC} Go" || echo -e "${RED}[MISSING]${NC} Go"
    command -v python3 &> /dev/null && echo -e "${GREEN}[OK]${NC} Python3" || echo -e "${RED}[MISSING]${NC} Python3"
    command -v pip3 &> /dev/null && echo -e "${GREEN}[OK]${NC} pip3" || echo -e "${RED}[MISSING]${NC} pip3"
    command -v node &> /dev/null && echo -e "${GREEN}[OK]${NC} Node.js" || echo -e "${RED}[MISSING]${NC} Node.js"
    command -v npm &> /dev/null && echo -e "${GREEN}[OK]${NC} npm" || echo -e "${RED}[MISSING]${NC} npm"

    # Check Rust packages (only if Cargo is available)
    if command -v cargo &> /dev/null; then
        local cargo_bin_path="$HOME/.cargo/bin"
        [[ -f "$cargo_bin_path/eza" ]] && echo -e "${GREEN}[OK]${NC} eza (modern ls replacement)" || echo -e "${RED}[MISSING]${NC} eza"
    else
        echo -e "${RED}[MISSING]${NC} eza (Cargo not available)"
    fi

    # Check Go tools (only if Go is available)
    if command -v go &> /dev/null; then
        local go_bin_path="$(go env GOPATH 2>/dev/null)/bin"
        [[ -f "$go_bin_path/hcloud" ]] && echo -e "${GREEN}[OK]${NC} Hetzner Cloud CLI" || echo -e "${RED}[MISSING]${NC} Hetzner Cloud CLI"
        [[ -f "$go_bin_path/go-blueprint" ]] && echo -e "${GREEN}[OK]${NC} Go Blueprint" || echo -e "${RED}[MISSING]${NC} Go Blueprint"
        [[ -f "$go_bin_path/gdu" ]] && echo -e "${GREEN}[OK]${NC} GDU (disk usage analyzer)" || echo -e "${RED}[MISSING]${NC} GDU (disk usage analyzer)"
    else
        echo -e "${RED}[MISSING]${NC} Hetzner Cloud CLI (Go not available)"
        echo -e "${RED}[MISSING]${NC} Go Blueprint (Go not available)"
        echo -e "${RED}[MISSING]${NC} GDU (Go not available)"
    fi

    # Check Python packages
    if command -v ansible &> /dev/null || [[ -f "$HOME/.local/bin/ansible" ]]; then
        echo -e "${GREEN}[OK]${NC} Ansible"
    else
        echo -e "${RED}[MISSING]${NC} Ansible"
    fi

    # Check npm packages
    if command -v claude-code &> /dev/null || npm list -g @anthropic-ai/claude-code &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} Claude Code CLI"
    else
        echo -e "${RED}[MISSING]${NC} Claude Code CLI"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Display post-installation notes
    if command -v az &> /dev/null; then
        echo ""
        log_info "Azure CLI Post-Installation Notes:"
        echo "  • Sign in with: az login"
        echo "  • Update with: az upgrade"
        echo "  • Check version: az version"
        echo "  • Get help: az --help"
    fi
}

# Main execution
main() {
    log_info "Starting system setup..."

    check_root
    check_sudo
    update_system
    install_base_deps
    install_brave
    install_github_cli
    install_azure_cli

    # Handle Rust installation
    if ! check_rust; then
        log_info "Installing Rust..."
        install_rust
        if check_rust; then
            install_cargo_packages
        else
            log_warning "Skipping Rust packages installation due to Rust installation failure"
        fi
    else
        install_cargo_packages
    fi

    if check_go; then
        install_go_tools
    else
        log_warning "Skipping Go tools installation due to missing Go"
    fi

    if check_python; then
        install_pip_packages
    else
        log_warning "Skipping pip packages installation due to missing Python/pip"
    fi

    if check_nodejs; then
        install_npm_packages
    else
        log_warning "Skipping npm packages installation due to missing Node.js/npm"
    fi

    show_summary
    log_success "Setup completed!"
    log_info "Please restart your terminal or run 'source ~/.bashrc' to ensure all PATH changes take effect."
}

# Run main function
main "$@"
