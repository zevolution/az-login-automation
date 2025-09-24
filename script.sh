#!/bin/bash

set -e

######### MAIN VARIABLES ##########
TENANT_CHOICE=${1}
FIREFOX_CONTAINER_NAME=${2}
FIREFOX_BIN_PATH="/folder"
###################################

if [ $# -gt 0 ]; then
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        TENANT_CHOICE="$1"
    else
        echo -e "${RED}Error: Parameter must be a number (tenant index)${NC}"
        echo "Usage: $0 [tenant_number]"
        echo "Example: $0 5"
        exit 1
    fi
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

cleanup_function() {
    echo ""
    if [ -n "$expect_script" ] && [ -f "$expect_script" ]; then
        rm -f "$expect_script"
    fi
    if [ -n "$temp_file" ] && [ -f "$temp_file" ]; then
        rm -f "$temp_file"
    fi
    echo -e "${RED}✗ Azure login interruped by user${NC}"
    exit 130
}

trap cleanup_function SIGINT

detect_clipboard() {
    if command -v pbcopy >/dev/null 2>&1; then
        echo "pbcopy"
    elif command -v xclip >/dev/null 2>&1; then
        echo "xclip"
    elif command -v xsel >/dev/null 2>&1; then
        echo "xsel"
    elif command -v clip.exe >/dev/null 2>&1; then
        echo "clip.exe"
    else
        echo "none"
    fi
}

copy_to_clipboard() {
    local text="$1"
    local clipboard_cmd=$(detect_clipboard)
    
    case $clipboard_cmd in
        "pbcopy")
            echo -n "$text" | pbcopy
            ;;
        "xclip")
            echo -n "$text" | xclip -selection clipboard
            ;;
        "xsel")
            echo -n "$text" | xsel --clipboard --input
            ;;
        "clip.exe")
            echo -n "$text" | clip.exe
            ;;
        "none")
            echo -e "${RED}No clipboard utility found. Please install pbcopy (macOS), xclip/xsel (Linux), or use WSL with clip.exe (Windows)${NC}"
            return 1
            ;;
    esac
    return 0
}

if ! command -v az >/dev/null 2>&1; then
    echo -e "${RED}Error: Azure CLI (az) is not installed or not in PATH${NC}"
    echo "Please install Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    exit 1
fi

echo -e "${BLUE}Starting Azure device code authentication...${NC}"

temp_file=$(mktemp)
if command -v expect >/dev/null 2>&1; then
    expect_script=$(mktemp)
    cat > "$expect_script" << 'EXPECTEOF'
#!/usr/bin/expect -f

proc cleanup_expect {} {
    exit 130
}

trap {cleanup_expect} SIGINT

proc copy_to_clipboard {text} {
    global env
    set clipboard_cmd $env(CLIPBOARD_CMD)
    
    switch $clipboard_cmd {
        "pbcopy" {
            exec echo -n $text | pbcopy
        }
        "xclip" {
            exec echo -n $text | xclip -selection clipboard
        }
        "xsel" {
            exec echo -n $text | xsel --clipboard --input
        }
        "clip.exe" {
            exec echo -n $text | clip.exe
        }
        default {
            return 0
        }
    }
    return 1
}

proc handle_selection_prompt {tenant_choice} {
    if {$tenant_choice != ""} {
        log_user 1
        puts "\033\[32m\[SCRIPT\] Auto-selecting option: \[$tenant_choice\]\033\[0m"
		put ""
        log_user 0
        send "$tenant_choice\r"
        return 0
    } else {
        log_user 1
        interact {
            \003 {
				        puts ""
				        puts ""
				        puts "\033\[0;31m ✗ Azure login interruped by user\033\[0m"
                exit 130
            }
        }
        return 0
    }
}

set device_code_found 0
set tenant_choice $env(TENANT_CHOICE)
set login_completed 0
set firefox_container_name $env(FIREFOX_CONTAINER_NAME)
set firefox_bin_path $env(FIREFOX_BIN_PATH)

log_user 0

spawn az login --use-device-code
set timeout 120

expect {
    -re {([A-Z0-9-]{8,15})} {
        if {$device_code_found == 0} {
            set device_code $expect_out(1,string)
            
            log_user 1
            puts "\n\033\[32m\[SCRIPT\] ✓ Device code detected: \033\[33m$device_code\033\[0m"
            
            if {[copy_to_clipboard $device_code]} {
                puts "\033\[32m\[SCRIPT\] ✓ Device code copied to clipboard!\033\[0m"
				        puts ""
                puts "\033\[34m\[SCRIPT\] Opening Firefox container...\033\[0m"
                
                catch {exec $firefox_bin_path/firefox --new-tab "ext+container:name=$firefox_container_name&url=https://microsoft.com/devicelogin" &}
                
                puts "\033\[34m\[SCRIPT\] Firefox opened at: https://microsoft.com/devicelogin\033\[0m"
				        puts ""
            } else {
                puts "\033\[33m\[SCRIPT\] Please manually copy this code: $device_code\033\[0m"
                puts "\033\[34m\[SCRIPT\] Then go to: https://microsoft.com/devicelogin\033\[0m"
            }
            
            if {$tenant_choice != ""} {
                puts "\033\[36m\[SCRIPT\] Will auto-select option \[$tenant_choice\] after authentication...\033\[0m"
				        log_user 0
            }
            puts ""
            set device_code_found 1
        }
        exp_continue
    }
    -re {\[Tenant and subscription selection\]} {
        if {$tenant_choice == ""} {
            log_user 1
        } else {
            log_user 0
        }
        exp_continue
    }
    -re {Select a subscription and tenant.*:} {
        if {[handle_selection_prompt $tenant_choice] == 0} {
            return
        }
        exp_continue
    }
    -re {Type a number or Enter.*:} {
        if {[handle_selection_prompt $tenant_choice] == 0} {
            return
        }
        exp_continue
    }
    eof {
        if {$login_completed == 0} {
            log_user 1
            puts "\n\033\[32m\[SCRIPT\] Process completed\033\[0m"
			      puts ""
        }
    }
    timeout {
        log_user 1
        puts "\n\033\[31m\[SCRIPT\] Timeout waiting for response. Current buffer:\033\[0m"
        puts $expect_out(buffer)
        puts "\033\[33m\[SCRIPT\] Switching to manual mode...\033\[0m"
        interact {
            \003 {
				        puts "\033\[0;31m ✗ Azure login interruped by user\033\[0m"
                exit 130
            }
        }
    }
}
EXPECTEOF

    export CLIPBOARD_CMD=$(detect_clipboard)
    export TENANT_CHOICE="$TENANT_CHOICE"
	  export FIREFOX_CONTAINER_NAME="$FIREFOX_CONTAINER_NAME"
	  export FIREFOX_BIN_PATH="$FIREFOX_BIN_PATH"
    
    chmod +x "$expect_script"
    "$expect_script"
    login_exit_code=$?
    
    if [ $login_exit_code -eq 130 ]; then
        echo -e "${RED}✗ Azure login interruped by user${NC}"
        exit 130
    fi
    
    rm -f "$expect_script"
    
else
    echo -e "${RED}Error: 'expect' command not found. This script requires expect to be installed.${NC}"
    echo -e "${YELLOW}Install expect with:${NC}"
    echo -e "${YELLOW}  macOS: brew install expect${NC}"
    echo -e "${YELLOW}  Ubuntu/Debian: sudo apt-get install expect${NC}"
    echo -e "${YELLOW}  CentOS/RHEL: sudo yum install expect${NC}"
    login_exit_code=1
fi

rm -f "$temp_file"

if [ $login_exit_code -eq 0 ]; then
    echo -e "${GREEN}✓ Azure login completed successfully!${NC}"
else
    echo -e "${RED}✗ Azure login failed with exit code $login_exit_code${NC}"
    exit $login_exit_code
fi
