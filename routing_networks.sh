#!/bin/bash

# Validamos si se ingresó los IDs de las dos VLAN al ejecutar el script
if [ "$#" -ne 2 ]; then
    echo "Error: Debe indicar los IDs de las dos VLAN que desea interconectar."
    echo "Ejm: ./routing_networks.sh 100 200"
    exit 1
fi

VLAN1="$1"
VLAN2="$2"

GW1="gw_vlan${VLAN1}"
GW2="gw_vlan${VLAN2}"

# Permitimos el tráfico de VLAN1 a VLAN2
sudo iptables -A FORWARD \
    -i "$GW1" \
    -o "$GW2" \
    -j ACCEPT

# Permitimos el tráfico de VLAN2 a VLAN1
sudo iptables -A FORWARD \
    -i "$GW2" \
    -o "$GW1" \
    -j ACCEPT

echo "Routing entre VLAN $VLAN1 y VLAN $VLAN2 habilitado."

