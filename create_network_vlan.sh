#!/bin/bash

# Validamos si se ingresó los parametros de entrada requeridos: ID Vlan, Red en formato CIDR , habilitación de DHCP y Rango DHCP si aplica , al ejecutar el script
if [ "$#" -lt 3 ]; then
    echo "Error: Debe indicar el ID de VLAN, la red en formato CIDR , si DHCP estará habilitado y el rango DHCP si se habilita."
    echo "Ejm: ./create_network_vlan.sh 100 192.168.0.0/24 disabled"
    echo "También puede indicar el rango DHCP si lo habilita"
    echo "Ejm: ./create_network_vlan.sh 200 192.168.2.0/24 enabled 192.168.2.11,192.168.2.15"
    exit 1
fi

VLAN_ID="$1"
NETWORK="$2"
DHCP="$3"
DHCP_RANGE="$4"

# Validamos la VLAN ID
if ! [[ "$VLAN_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: El ID de VLAN debe ser un número."
    echo "Ejm: ./create_network_vlan.sh 100 192.168.0.0/24 disabled"
    exit 1
fi

# Obtenemos la dirección de red y máscara
NETWORK_IP=$(echo "$NETWORK" | cut -d'/' -f1)
PREFIX=$(echo "$NETWORK" | cut -d'/' -f2)

# Obtenemos el primer host de la red como gateway
GATEWAY=$(python3 -c "
import ipaddress
net = ipaddress.ip_network('$NETWORK', strict=False)
print(list(net.hosts())[0])
")

# Nombre de la interfaz interna
GW_INTERFACE="gw_vlan${VLAN_ID}"

echo "Creando VLAN $VLAN_ID..."
echo "Red: $NETWORK"
echo "Gateway: $GATEWAY"

# Creamos la interfaz interna del bridge ovs br-int si no existe
if ! sudo ovs-vsctl list-ports br-int | grep -q "^${GW_INTERFACE}$"; then

    sudo ovs-vsctl add-port br-int "$GW_INTERFACE" \
        -- set interface "$GW_INTERFACE" type=internal

fi

# Configuramos la VLAN
sudo ovs-vsctl set port "$GW_INTERFACE" tag="$VLAN_ID"

# Levantamos la interfaz
sudo ip link set "$GW_INTERFACE" up

# Configuramos el gateway
sudo ip addr flush dev "$GW_INTERFACE"
sudo ip addr add "$GATEWAY/$PREFIX" dev "$GW_INTERFACE"

echo "Interfaz $GW_INTERFACE configurada con $GATEWAY/$PREFIX."

# Configuración DHCP
if [ "$DHCP" = "enabled" ]; then

    if [ -z "$DHCP_RANGE" ]; then
        echo "Error: Debe indicar el rango DHCP cuando DHCP está habilitado."
        echo "Ejm: ./create_network_vlan.sh 200 192.168.2.0/24 enabled 192.168.2.11,192.168.2.15"
        exit 1
    fi

    echo "DHCP habilitado."
    echo "Rango DHCP: $DHCP_RANGE"

    # Obtenemos el segundo host de la red para el servidor DHCP
    DHCP_SERVER_IP=$(python3 -c "
import ipaddress
net = ipaddress.ip_network('$NETWORK', strict=False)
hosts = list(net.hosts())
print(hosts[1])
")

    NS_NAME="ns-dhcp-vlan${VLAN_ID}"
    VETH_OVS="dhcp_v${VLAN_ID}"
    VETH_NS="dhcp_ns_v${VLAN_ID}"

    # Creamos el namespace si no existe
    if ! sudo ip netns list | grep -q "^${NS_NAME}$"; then
        sudo ip netns add "$NS_NAME"
    fi

    # Creamos el enlace veth si no existe
    if ! sudo ip link show "$VETH_OVS" >/dev/null 2>&1; then

        sudo ip link add "$VETH_OVS" type veth peer name "$VETH_NS"

        sudo ip link set "$VETH_NS" netns "$NS_NAME"

        sudo ovs-vsctl add-port br-int "$VETH_OVS" \
            tag="$VLAN_ID"

    fi

    # Configuramos la interfaz dentro del namespace
    sudo ip netns exec "$NS_NAME" ip link set lo up
    sudo ip netns exec "$NS_NAME" ip link set "$VETH_NS" up

    sudo ip netns exec "$NS_NAME" ip addr flush dev "$VETH_NS"
    sudo ip netns exec "$NS_NAME" ip addr add \
        "$DHCP_SERVER_IP/$PREFIX" dev "$VETH_NS"

    # Obtenemos el rango DHCP
    DHCP_START=$(echo "$DHCP_RANGE" | cut -d',' -f1)
    DHCP_END=$(echo "$DHCP_RANGE" | cut -d',' -f2)

    # Detenemos el servicio DHCP "dnsmasq" anterior , si existe
    sudo ip netns exec "$NS_NAME" pkill dnsmasq 2>/dev/null

    # Levantamos el servidor DHCP
    sudo ip netns exec "$NS_NAME" dnsmasq \
        --interface="$VETH_NS" \
        --bind-interfaces \
        --dhcp-range="$DHCP_START,$DHCP_END" \
        --dhcp-option=3,"$GATEWAY" \
        --dhcp-option=6,"$GATEWAY" \
        --port=0 \
        --pid-file=/tmp/dnsmasq-vlan${VLAN_ID}.pid

    echo "Servidor DHCP configurado."
    echo "Namespace: $NS_NAME"
    echo "IP DHCP: $DHCP_SERVER_IP"

elif [ "$DHCP" = "disabled" ]; then

    echo "DHCP deshabilitado."

else

    echo "Error: El parámetro DHCP debe ser 'enabled' o 'disabled'."
    echo "Ejm: ./create_network_vlan.sh 100 192.168.0.0/24 disabled"
    echo "También puede habilitar DHCP , e indicar el rango de direcciones"
    echo "Ejm: ./create_network_vlan.sh 200 192.168.2.0/24 enabled 192.168.2.11,192.168.2.15"
    exit 1

fi

echo "Red VLAN $VLAN_ID creada correctamente."

