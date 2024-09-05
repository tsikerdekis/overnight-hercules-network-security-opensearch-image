#!/bin/bash

# Function to prompt for variable if not set in .env file
prompt_if_empty() {
    local var_name=$1
    local var_value=$2
    local prompt_message=$3

    # If the variable is empty, prompt for it
    if [ -z "$var_value" ]; then
        read -p "$prompt_message: " var_value
        echo "$var_name=$var_value" >> .env
    fi

    # Export the variable to the environment
    export $var_name=$var_value
}

# Load existing .env file if it exists
if [ -f ".env" ]; then
    source .env
fi

# Prompt for environment variables if they are not set
prompt_if_empty "NETWORK_INTERFACE" "$NETWORK_INTERFACE" "Enter the network interface"
prompt_if_empty "SYSTEM_RAM" "$SYSTEM_RAM" "Enter the system RAM (e.g., 5000m)"
prompt_if_empty "OPENSEARCH_INITIAL_ADMIN_PASSWORD" "$OPENSEARCH_INITIAL_ADMIN_PASSWORD" "Enter the OpenSearch admin password"
prompt_if_empty "LOCAL_SUBNET_WILD" "$LOCAL_SUBNET_WILD" "Enter your local subnet in wildcard format (e.g., 192.168.1.*)"

# Apply necessary system configurations
sudo sysctl -w vm.max_map_count=262144

# Enable promiscuous mode for the network interface
sudo ip link set $NETWORK_INTERFACE promisc on

# Modify fluent-bit.conf to replace LOCAL_SUBNET_WILD and OPENSEARCH_INITIAL_ADMIN_PASSWORD
if [ -f "fluent-bit.conf" ]; then
    # Use sed to replace the subnet wildcard in the configuration file
    sed -i "s/192\.168\.1\.\*/$LOCAL_SUBNET_WILD/g" fluent-bit.conf
    echo "Updated fluent-bit.conf with LOCAL_SUBNET_WILD = $LOCAL_SUBNET_WILD"

    # Use sed to replace the HTTP_Passwd with OPENSEARCH_INITIAL_ADMIN_PASSWORD
    sed -i "s/HTTP_Passwd\s*.*/HTTP_Passwd     $OPENSEARCH_INITIAL_ADMIN_PASSWORD/g" fluent-bit.conf
    echo "Updated fluent-bit.conf with OPENSEARCH_INITIAL_ADMIN_PASSWORD"
else
    echo "fluent-bit.conf not found!"
fi

# Start Docker Compose
sudo docker compose up -d
