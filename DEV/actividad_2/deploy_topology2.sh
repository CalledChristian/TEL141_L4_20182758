#!/bin/bash

set -euo pipefail

# ============================================================
# Actividad 2: Redes aisladas SIN DHCP y CON salida a Internet
#
# Este script se ejecuta desde Server4 (Headnode)
# Los scripts modulares (del Inf. Previo) se encuentran en la raiz del repositorio.
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVER1="10.0.10.1"
SERVER2="10.0.10.2"
SERVER3="10.0.10.3"
SSH_USER="ubuntu"

VLAN100="100"
NET100="192.168.0.0/24"
IP100_CONTAINER="192.168.0.10/24"
IP100_VM="192.168.0.20/24"
GW100="192.168.0.1"
VNC100="5901"

VLAN200="200"
NET200="192.168.2.0/24"
IP200_CONTAINER="192.168.2.10/24"
IP200_VM="192.168.2.20/24"
GW200="192.168.2.1"
VNC200="5902"

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
# 0. Verificacion de conectividad SSH desde Server4
# ------------------------------------------------------------
log "0. Verificando acceso SSH desde Server4"

check_ssh "$SERVER1"
check_ssh "$SERVER2"
check_ssh "$SERVER3"

# ------------------------------------------------------------
# 1. Inicializar nodos del cluster
#
# Server1 y Server2: workers
# Server3: master / nodo de red
# ens4 = red de datos
# ens3 = red de gestion/salida a Internet
# ------------------------------------------------------------
log "1. Inicializando la topologia OVS"

run_remote_script "$SERVER1" "$ROOT_DIR/init_worker.sh" ens4
run_remote_script "$SERVER2" "$ROOT_DIR/init_worker.sh" ens4
run_remote_script "$SERVER3" "$ROOT_DIR/init_master.sh" ens4

# ------------------------------------------------------------
# 2. Crear las redes VLAN en Server3 SIN DHCP
# ------------------------------------------------------------
log "2. Creando VLAN 100 y VLAN 200 sin DHCP en Server3"

run_remote_script "$SERVER3" "$ROOT_DIR/create_network_vlan.sh" \
    "$VLAN100" "$NET100" disabled

run_remote_script "$SERVER3" "$ROOT_DIR/create_network_vlan.sh" \
    "$VLAN200" "$NET200" disabled

# ------------------------------------------------------------
# 3. Habilitar salida a Internet mediante NAT
# ------------------------------------------------------------
log "3. Habilitando salida a Internet para ambas VLAN"

run_remote_script "$SERVER3" "$ROOT_DIR/internet_to_network.sh" \
    "$VLAN100" "$NET100"

run_remote_script "$SERVER3" "$ROOT_DIR/internet_to_network.sh" \
    "$VLAN200" "$NET200"

# ------------------------------------------------------------
# 4. Habilitar IPTABLES 1: ruteo entre VLANs
#
# La topologia de la Actividad 2 incluye:
#   IPTABLES 1 -> ruteo entre VLANs
#   IPTABLES 2 -> salida a Internet
# ------------------------------------------------------------
log "4. Habilitando ruteo entre VLAN 100 y VLAN 200"

run_remote_script "$SERVER3" "$ROOT_DIR/routing_networks.sh" \
    "$VLAN100" "$VLAN200"

# El script init_master.sh deja FORWARD en DROP. 
# Por ello se habilita la salida de cada VLAN hacia ens3 y el retorno.
log "5. Configurando firewall para salida a Internet"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<'REMOTE_FIREWALL'
set -e

sudo iptables -C FORWARD -i gw_vlan100 -o ens3 -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -i gw_vlan100 -o ens3 -j ACCEPT

sudo iptables -C FORWARD -i gw_vlan200 -o ens3 -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -i gw_vlan200 -o ens3 -j ACCEPT

sudo iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

echo "Reglas FORWARD para salida a Internet configuradas."
REMOTE_FIREWALL

# ------------------------------------------------------------
# 6. Crear los contenedores en Server1 y asignar IP estatica
#
# Se reutiliza el direccionamiento empleado en Lab 3:
#   VLAN100 -> .10/24, gateway .1
#   VLAN200 -> .10/24, gateway .1
# ------------------------------------------------------------
log "6. Creando contenedores en Server1 con IP estatica"

ssh "${SSH_USER}@${SERVER1}" 'bash -s' <<REMOTE_CONTAINERS
set -e

create_container() {
    local name="\$1"
    local ovs_port="\$2"
    local container_veth="\$3"
    local vlan="\$4"
    local ip_cidr="\$5"
    local gateway="\$6"

    echo ">> Configurando \$name en VLAN \$vlan..."

    if docker ps -a --format '{{.Names}}' | grep -qx "\$name"; then
        echo "Error: el contenedor \$name ya existe."
        echo "Ejecute cleanup_environment.sh antes de volver a desplegar."
        exit 1
    fi

    docker run --rm \
        --network none \
        --name "\$name" \
        --cap-add=NET_ADMIN \
        -d alpine sleep infinity >/dev/null

    PID="\$(docker inspect -f '{{.State.Pid}}' "\$name")"

    sudo ip link add "\$ovs_port" type veth peer name "\$container_veth"
    sudo ip link set "\$container_veth" netns "\$PID"

    sudo ovs-vsctl add-port br-int "\$ovs_port" tag="\$vlan"
    sudo ip link set "\$ovs_port" up

    sudo nsenter -t "\$PID" -n ip link set lo up
    sudo nsenter -t "\$PID" -n ip link set "\$container_veth" name eth1
    sudo nsenter -t "\$PID" -n ip link set eth1 up
    sudo nsenter -t "\$PID" -n ip addr add "\$ip_cidr" dev eth1
    sudo nsenter -t "\$PID" -n ip route add default via "\$gateway"

    echo "\$name conectado a VLAN \$vlan."
    echo "  IP: \$ip_cidr"
    echo "  Gateway: \$gateway"
}

create_container \
    container_vlan100 \
    veth_ovs \
    veth_container \
    100 \
    "${IP100_CONTAINER}" \
    "${GW100}"

create_container \
    container_vlan200 \
    veth_ovs_200 \
    veth_cont_200 \
    200 \
    "${IP200_CONTAINER}" \
    "${GW200}"
REMOTE_CONTAINERS

# ------------------------------------------------------------
# 7. Crear las dos VMs en Server2
#
# El script create_vm.sh conserva los 4 parametros de entrada definidos en el Inf.Previo
# La configuracion IP del guest se realiza dentro de cada VM, tal como se hizo en Lab 3.
#
# Direccionamiento previsto:
#   VM VLAN100 -> 192.168.0.20/24 -> GW100 192.168.0.1
#   VM VLAN200 -> 192.168.2.20/24 -> GW200 192.168.2.1
# ------------------------------------------------------------
log "7. Creando VMs en Server2"

echo ">> VM VLAN 100: IP prevista ${IP100_VM}, gateway ${GW100}"
run_remote_script "$SERVER2" "$ROOT_DIR/create_vm.sh" \
    vm_vlan100 br-int "$VLAN100" "$VNC100"

echo ">> VM VLAN 200: IP prevista ${IP200_VM}, gateway ${GW200}"
run_remote_script "$SERVER2" "$ROOT_DIR/create_vm.sh" \
    vm_vlan200 br-int "$VLAN200" "$VNC200"

# ------------------------------------------------------------
# 8. Verificacion basica de la topologia
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
echo "[Direccionamiento de los contenedores]"
for c in container_vlan100 container_vlan200; do
    echo "### $c"
    PID=$(docker inspect -f "{{.State.Pid}}" "$c")
    sudo nsenter -t "$PID" -n ip -br addr
    sudo nsenter -t "$PID" -n ip route
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
echo "[Namespaces DHCP - no deben existir en Actividad 2]"
sudo ip netns list | grep "ns-dhcp-vlan" || true
echo
echo "[IP forwarding]"
sysctl net.ipv4.ip_forward
echo
echo "[iptables FILTER]"
sudo iptables -L FORWARD -n -v --line-numbers
echo
echo "[iptables NAT]"
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
'

log "DESPLIEGUE DE TOPOLOGIA 2 FINALIZADO"

echo "Topologia desplegada:"
echo "  VLAN 100 -> 192.168.0.0/24 -> SIN DHCP -> Internet"
echo "  VLAN 200 -> 192.168.2.0/24 -> SIN DHCP -> Internet"
echo "  Server1 -> contenedores con IP estatica"
echo "  Server2 -> VMs con direccionamiento estatico previsto"
echo "  Server3 -> gateways + NAT + ruteo entre VLANs"
echo "  VLAN 100 <-> VLAN 200 -> CON ENRUTAMIENTO"
echo
echo "Direccionamiento previsto para los endpoints:"
echo "  container_vlan100 -> ${IP100_CONTAINER} via ${GW100}"
echo "  container_vlan200 -> ${IP200_CONTAINER} via ${GW200}"
echo "  vm_vlan100       -> ${IP100_VM} via ${GW100}"
echo "  vm_vlan200       -> ${IP200_VM} via ${GW200}"
