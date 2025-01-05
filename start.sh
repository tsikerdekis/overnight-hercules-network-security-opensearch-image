#!/bin/bash

sudo docker compose down

prompt_if_empty() {
    local var_name=$1
    local var_value=$2
    local prompt_message=$3
    local validate_password=$4

    # If the variable is empty, prompt for it
    while [ -z "$var_value" ]; do
        read -p "$prompt_message: " var_value

        # Validate the password strength if required
        if [ "$validate_password" = "true" ]; then
            check_password_strength "$var_value"
            if [ $? -ne 0 ]; then
                echo "Password is too weak. Please try again."
                var_value=""  # Reset to force re-prompt
            fi
        fi
    done

    # Save to .env and export the variable to the environment
    echo "$var_name=$var_value" >> .env
    export $var_name=$var_value
}

install_zxcvbn() {
    # Determine package manager
    if [ -x "$(command -v apt)" ]; then
        sudo apt update
        sudo apt install -y python3-zxcvbn
    elif [ -x "$(command -v yum)" ]; then
        sudo yum install -y python3-zxcvbn
    elif [ -x "$(command -v dnf)" ]; then
        sudo dnf install -y python3-zxcvbn
    else
        echo "Unsupported package manager. Install python3-zxcvbn manually."
        exit 1
    fi
}

check_password_strength() {
    local password=$1
    local score=$(echo "$password" | python3 -c "import sys; from zxcvbn import zxcvbn; print(zxcvbn(sys.stdin.read().strip())['score'])")
    if [ "$score" -ge 3 ]; then
        return 0  # Strong password
    else
        return 1  # Weak password
    fi
}

# Install zxcvbn if not already installed
if ! python3 -c "import zxcvbn" &>/dev/null; then
    echo "Installing python3-zxcvbn..."
    install_zxcvbn
fi

# Load existing .env file if it exists
if [ -f ".env" ]; then
    source .env
fi

# Prompt for environment variables if they are not set
prompt_if_empty "NETWORK_INTERFACE" "$NETWORK_INTERFACE" "Enter the network interface"
prompt_if_empty "SYSTEM_RAM" "$SYSTEM_RAM" "Enter the system RAM (e.g., 5000m)"
prompt_if_empty "OPENSEARCH_INITIAL_ADMIN_PASSWORD" "$OPENSEARCH_INITIAL_ADMIN_PASSWORD" "Enter the OpenSearch admin password" "true"


# Apply necessary system configurations
sudo sysctl -w vm.max_map_count=262144

# Enable promiscuous mode for the network interface
sudo ip link set $NETWORK_INTERFACE promisc on

# Modify fluent-bit.conf to replace OPENSEARCH_INITIAL_ADMIN_PASSWORD
if [ -f "fluent-bit.conf" ]; then
    SUBNET=$(ip -o -f inet addr show $NETWORK_INTERFACE | awk '/scope global/ {print $4}')
    SUBNET_BASE=$(echo $SUBNET | cut -d'.' -f1-3)

    if [ -z "$SUBNET_BASE" ]; then
      echo "Could not determine the subnet base for $NETWORK_INTERFACE."
      exit 1
    fi

    # Use wildcard notation (e.g., 192.168.1.*)
    SUBNET_WILDCARD="${SUBNET_BASE}.*"

    # Replace the src_ip and dest_ip condition lines in fluent-bit.conf
    sed -i "s/Condition Key_Value_Does_Not_Match src_ip .*/Condition Key_Value_Does_Not_Match src_ip $SUBNET_WILDCARD/" fluent-bit.conf
    sed -i "s/Condition Key_Value_Does_Not_Match dest_ip .*/Condition Key_Value_Does_Not_Match dest_ip $SUBNET_WILDCARD/" fluent-bit.conf

    echo "fluent-bit.conf updated with subnet: $SUBNET_WILDCARD"

    # Use sed to replace the HTTP_Passwd with OPENSEARCH_INITIAL_ADMIN_PASSWORD
    sed -i "s/HTTP_Passwd\s*.*/HTTP_Passwd     $OPENSEARCH_INITIAL_ADMIN_PASSWORD/g" fluent-bit.conf
    echo "Updated fluent-bit.conf with OPENSEARCH_INITIAL_ADMIN_PASSWORD"
else
    echo "fluent-bit.conf not found!"
fi

# Download GeoLite2-City.mmdb if it does not exist
if [ ! -f "GeoLite2-City.mmdb" ]; then
    echo "GeoLite2-City.mmdb not found! Attempting to download..."
    wget -O GeoLite2-City.mmdb https://git.io/GeoLite2-City.mmdb

    # Check if the download was successful
    if [ ! -f "GeoLite2-City.mmdb" ]; then
        echo "Failed to download GeoLite2-City.mmdb. Please download it manually."
        exit 1
    else
        echo "Successfully downloaded GeoLite2-City.mmdb."
    fi
else
    echo "GeoLite2-City.mmdb already exists."
fi

sudo docker compose pull

# Check if the opensearch-data1 directory exists
if [ ! -d "opensearch-data1" ]; then
    echo "First run detected. Bringing up opensearch-node1."

    # Start only opensearch-node1
    sudo docker compose up -d opensearch-node1

    echo "Waiting for AccessDeniedException error in logs..."

    # Wait for the specific log message
    until sudo docker logs opensearch-node1 2>&1 | grep -q "java.nio.file.AccessDeniedException: /usr/share/opensearch/data/nodes"; do
        sleep 5
    done

    echo "Error detected. Stopping opensearch-node1..."

    # Stop the opensearch-node1 container
    sudo docker compose stop opensearch-node1

    # Fix the permissions of the data folder
    echo "Fixing permissions for opensearch-data1..."
    sudo chmod -R 777 opensearch-data1

    # Restart opensearch-node1
    echo "Restarting opensearch-node1..."
    sudo docker compose up -d opensearch-node1 opensearch-dashboards

    # Wait for the node to initialize
    echo "Waiting for 'Node initialized' in logs..."

    until sudo docker logs opensearch-node1 2>&1 | grep -q "Node 'opensearch-node1' initialized"; do
        sleep 5
    done

    echo "Node 'opensearch-node1' initialized. Proceeding with the next steps."

  # Apply the field mappings using the opensearch-fields.json file
  if [ -f "opensearch-fields.json" ]; then
      echo "Applying index template from opensearch-fields.json..."

      # Use curl to apply the index template
      curl -X PUT "https://localhost:9200/_index_template/logstash_template" \
        -u admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD \
        -H "Content-Type: application/json" \
        -d @opensearch-fields.json \
        --insecure

      if [ $? -eq 0 ]; then
          echo "Index template successfully applied."
      else
          echo "Failed to apply the index template."
          exit 1
      fi
  else
      echo "opensearch-fields.json file not found!"
      exit 1
  fi

  # Stop opensearch-node1 after applying the index template
  sudo docker compose stop opensearch-node1 opensearch-dashboards

fi

# Start the full Docker Compose environment
echo "Bringing up the full Docker Compose environment..."

# Start Docker Compose
sudo docker compose up -d
