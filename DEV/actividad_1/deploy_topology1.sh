#!/bin/bash

set -euo pipefail

# ============================================================
# Actividad 1: Redes aisladas con DHCP y salida a Internet
#
# Este script se ejecuta desde Server4 (Headnode).
# Los scripts modulares (del Inf. Previo) se encuentran en la raíz del repositorio.
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVER1="10.0.10.1"
SERVER2="10.0.10.2"
SERVER3="10.0.10.3"
SSH_USER="ubuntu"

VLAN100="100"
NET100="192.168.0.0/24"
DHCP100="192.168.0.11,192.168.0.15"

VLAN200="200"
NET200="192.168.2.0/24"
DHCP200="192.168.2.11,192.168.2.15"

OVS="br-int"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

run_remote_script() {
    local host="$1"
    local script="$2"
    shift 2

    echo ">> Ejecutando $(basename "$script") en $host..."
    ssh "${SSH_USER}@${host}" 'bash -s' < "$script" "$@"
}

check_ssh() {
    local host="$1"

    echo ">> Verificando SSH con $host..."
    ssh -o BatchMode=yes -o ConnectTimeout=5 \
        "${SSH_USER}@${host}" "hostname" >/dev/null
}

# ------------------------------------------------------------
# 0. Verificación de conectividad SSH desde Server4
# ------------------------------------------------------------
log "0. Verificando acceso SSH desde Server4"

check_ssh "$SERVER1"
check_ssh "$SERVER2"
check_ssh "$SERVER3"

# ------------------------------------------------------------
# 1. Inicializar nodos del clúster
#
# Server1 y Server2: workers
# Server3: master / nodo de red
# ens4 = red de datos
# ens3 = red de gestión/salida a Internet
# ------------------------------------------------------------
log "1. Inicializando la topología OVS"

run_remote_script "$SERVER1" "$ROOT_DIR/init_worker.sh" ens4
run_remote_script "$SERVER2" "$ROOT_DIR/init_worker.sh" ens4
run_remote_script "$SERVER3" "$ROOT_DIR/init_master.sh" ens4

# ------------------------------------------------------------
# 2. Crear las redes VLAN en Server3
#
# Actividad 1:
#   VLAN 100 -> 192.168.0.0/24 -> DHCP
#   VLAN 200 -> 192.168.2.0/24 -> DHCP
# ------------------------------------------------------------
log "2. Creando VLAN 100 y VLAN 200 con DHCP en Server3"

run_remote_script "$SERVER3" "$ROOT_DIR/create_network_vlan.sh" \
    "$VLAN100" "$NET100" enabled "$DHCP100"

run_remote_script "$SERVER3" "$ROOT_DIR/create_network_vlan.sh" \
    "$VLAN200" "$NET200" enabled "$DHCP200"

# ------------------------------------------------------------
# 3. Habilitar salida a Internet mediante NAT
# ------------------------------------------------------------
log "3. Habilitando salida a Internet para ambas VLAN"

run_remote_script "$SERVER3" "$ROOT_DIR/internet_to_network.sh" \
    "$VLAN100" "$NET100"

run_remote_script "$SERVER3" "$ROOT_DIR/internet_to_network.sh" \
    "$VLAN200" "$NET200"

# ------------------------------------------------------------
# 4. IPTABLES 1: ruteo entre VLAN 100 y VLAN 200
#
# La topologia de la Actividad 1 incluye:
#   IPTABLES 1 -> ruteo entre VLANs
#   IPTABLES 2 -> salida a Internet
# ------------------------------------------------------------
log "4. Habilitando ruteo entre VLAN 100 y VLAN 200"

run_remote_script "$SERVER3" "$ROOT_DIR/routing_networks.sh" \
    "$VLAN100" "$VLAN200"

# ------------------------------------------------------------
# 5. IPTABLES 2: reglas FORWARD necesarias para que el NAT funcione
#
# El script init_master.sh deja FORWARD en DROP.
# El script internet_to_network.sh solo agrega MASQUERADE.
# Por ello se permiten:
#   VLAN -> ens3
#   trafico de retorno ESTABLISHED/RELATED
# ------------------------------------------------------------
log "5. Configurando firewall para salida a Internet"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<'REMOTE_FIREWALL'
set -e

# Permitir tráfico desde las dos VLAN hacia Internet.
sudo iptables -C FORWARD -i gw_vlan100 -o ens3 -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -i gw_vlan100 -o ens3 -j ACCEPT

sudo iptables -C FORWARD -i gw_vlan200 -o ens3 -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -i gw_vlan200 -o ens3 -j ACCEPT

# Permitir únicamente el tráfico de retorno de conexiones existentes.
sudo iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "Reglas FORWARD para salida a Internet configuradas."
REMOTE_FIREWALL

# ------------------------------------------------------------
# 6. Crear los contenedores en Server1 y conectarlos a las VLAN
# ------------------------------------------------------------
log "6. Creando contenedores en Server1"

ssh "${SSH_USER}@${SERVER1}" 'bash -s' <<'REMOTE_CONTAINERS'
set -e

create_container() {
    local name="$1"
    local ovs_port="$2"
    local container_veth="$3"
    local vlan="$4"

    echo ">> Configurando $name en VLAN $vlan..."

    if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
        echo "Error: el contenedor $name ya existe."
        echo "Ejecute cleanup_environment.sh antes de volver a desplegar."
        exit 1
    fi

    docker run --rm \
        --network none \
        --name "$name" \
        --cap-add=NET_ADMIN \
        -d alpine sleep infinity >/dev/null

    PID="$(docker inspect -f '{{.State.Pid}}' "$name")"

    sudo ip link add "$ovs_port" type veth peer name "$container_veth"
    sudo ip link set "$container_veth" netns "$PID"

    sudo ovs-vsctl add-port br-int "$ovs_port" tag="$vlan"
    sudo ip link set "$ovs_port" up

    # Dentro del namespace del contenedor.
    sudo nsenter -t "$PID" -n ip link set lo up
    sudo nsenter -t "$PID" -n ip link set "$container_veth" name eth1
    sudo nsenter -t "$PID" -n ip link set eth1 up

    # Solicitar dirección por DHCP.
    sudo nsenter -t "$PID" -n udhcpc -i eth1 -b >/dev/null 2>&1 || true

    echo "$name conectado a VLAN $vlan."
}

create_container \
    container_vlan100 \
    veth_ovs \
    veth_container \
    100

create_container \
    container_vlan200 \
    veth_ovs_200 \
    veth_cont_200 \
    200
REMOTE_CONTAINERS

# ------------------------------------------------------------
# 7. Crear las dos VMs en Server2
#
# el script create_vm.sh genera:
#   - disco diferencial
#   - TAP
#   - conexión a br-int
#   - tag VLAN
#   - MAC
#   - QEMU + VNC
# ------------------------------------------------------------
log "7. Creando VMs en Server2"

run_remote_script "$SERVER2" "$ROOT_DIR/create_vm.sh" \
    vm_vlan100 br-int "$VLAN100" 5901

run_remote_script "$SERVER2" "$ROOT_DIR/create_vm.sh" \
    vm_vlan200 br-int "$VLAN200" 5902

# ------------------------------------------------------------
# 8. Verificación básica de la topología
# ------------------------------------------------------------
log "8. Verificando recursos desplegados"

echo
echo "----- Server1 -----"
ssh "${SSH_USER}@${SERVER1}" '
echo "[OVS]"
sudo ovs-vsctl show
echo
echo "[Contenedores]"
docker ps --format "table {{.Names}}\t{{.Status}}"
echo
echo "[Direcciones de los contenedores]"
for c in container_vlan100 container_vlan200; do
    echo "### $c"
    PID=$(docker inspect -f "{{.State.Pid}}" "$c")
    sudo nsenter -t "$PID" -n ip -br addr
done
'

echo
echo "----- Server2 -----"
ssh "${SSH_USER}@${SERVER2}" '
echo "[OVS]"
sudo ovs-vsctl show
echo
echo "[TAP]"
ip -br link show vm_vlan100_tap vm_vlan200_tap 2>/dev/null || true
echo
echo "[QEMU]"
pgrep -af "qemu-system-x86_64.*vm_vlan"
'

echo
echo "----- Server3 -----"
ssh "${SSH_USER}@${SERVER3}" '
echo "[OVS]"
sudo ovs-vsctl show
echo
echo "[Gateways]"
ip -br addr show gw_vlan100 gw_vlan200
echo
echo "[Namespaces DHCP]"
sudo ip netns list
echo
echo "[iptables FILTER]"
sudo iptables -L FORWARD -n -v
echo
echo "[iptables NAT]"
sudo iptables -t nat -L POSTROUTING -n -v
'

log "DESPLIEGUE DE TOPOLOGIA 1 FINALIZADO"

echo "Topología desplegada:"
echo "  VLAN 100 -> 192.168.0.0/24 -> DHCP -> Internet"
echo "  VLAN 200 -> 192.168.2.0/24 -> DHCP -> Internet"
echo "  Server1 -> contenedores"
echo "  Server2 -> VMs"
echo "  Server3 -> gateways + DHCP + NAT + ruteo entre VLANs"
echo "  VLAN 100 <-> VLAN 200 -> CON ENRUTAMIENTO"