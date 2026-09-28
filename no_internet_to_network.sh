#!/bin/bash

# Validamos si se ingresó el VLAN ID y la Red en formato CIDR al ejecutar el script
if [ "$#" -ne 2 ]; then
    echo "Error: Debe indicar el ID de VLAN y la red en formato CIDR."
    echo "Ejm: ./no_internet_to_network.sh 100 192.168.0.0/24"
    exit 1
fi

VLAN_ID="$1"
NETWORK="$2"

# Interfaz externa del nodo Master
EXTERNAL_INTERFACE="ens3"

# Eliminamos la regla NAT MASQUERADE (deshabilitar salida a internet) para la VLAN ingresada
sudo iptables -t nat -D POSTROUTING \
    -s "$NETWORK" \
    -o "$EXTERNAL_INTERFACE" \
    -j MASQUERADE

echo "Salida a Internet deshabilitada para VLAN $VLAN_ID."
echo "Red: $NETWORK"