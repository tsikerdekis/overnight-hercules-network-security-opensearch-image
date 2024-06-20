source .env
sudo sysctl -w vm.max_map_count=262144
sudo ip link set $NETWORK_INTERFACE promisc on
sudo docker compose up -d
