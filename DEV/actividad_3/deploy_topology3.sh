#!/bin/bash

set -euo pipefail

# ============================================================
# Actividad 3: Redes aisladas CON DHCP y SIN salida a Internet
#
# Este script se ejecuta desde Server4 (Headnode).
# Los scripts modulares (del Inf.Previo) se encuentran en la raiz del repositorio.
#
# Caracteristicas de la topologia:
#   - VLAN 100: DHCP + aislamiento + sin Internet
#   - VLAN 200: DHCP + aislamiento + sin Internet
#   - Server3 aloja un DHCP independiente para cada VLAN
#   - No se configuran reglas adicionales de NAT ni ruteo
#     entre las 2 VLAN.
# ============================================================

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVER1="10.0.10.1"
SERVER2="10.0.10.2"
SERVER3="10.0.10.3"
SSH_USER="ubuntu"

VLAN100="100"
NET100="192.168.0.0/24"
DHCP_RANGE100="192.168.0.11,192.168.0.15"
GW100="192.168.0.1"
VNC100="5901"

VLAN200="200"
NET200="192.168.2.0/24"
DHCP_RANGE200="192.168.2.11,192.168.2.15"
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
# ens3 = red de gestion
#
# El script init_master.sh deja FORWARD en DROP. 
# Para esta actividad: 
# NO se agregan reglas de NAT ni de ruteo inter-VLAN.
# ------------------------------------------------------------
log "1. Inicializando la topologia OVS"

run_remote_script "$SERVER1" "$ROOT_DIR/init_worker.sh" ens4
run_remote_script "$SERVER2" "$ROOT_DIR/init_worker.sh" ens4
run_remote_script "$SERVER3" "$ROOT_DIR/init_master.sh" ens4

# ------------------------------------------------------------
# 2. Crear las redes VLAN con DHCP en Server3
#
# Cada VLAN dispone de su propio namespace DHCP:
#   VLAN100 -> ns-dhcp-vlan100
#   VLAN200 -> ns-dhcp-vlan200
#
# Los rangos DHCP utilizados son:
#   VLAN100 -> 192.168.0.11 - 192.168.0.15
#   VLAN200 -> 192.168.2.11 - 192.168.2.15
# ------------------------------------------------------------
log "2. Creando VLAN 100 y VLAN 200 con DHCP en Server3"

echo ">> VLAN 100 -> DHCP ${DHCP_RANGE100}"
run_remote_script "$SERVER3" "$ROOT_DIR/create_network_vlan.sh" \
    "$VLAN100" "$NET100" enabled "$DHCP_RANGE100"

echo ">> VLAN 200 -> DHCP ${DHCP_RANGE200}"
run_remote_script "$SERVER3" "$ROOT_DIR/create_network_vlan.sh" \
    "$VLAN200" "$NET200" enabled "$DHCP_RANGE200"

# ------------------------------------------------------------
# 3. Sin salida a Internet
#
# No se ejecuta el script internet_to_network.sh.
# No se agrega la regla NAT MASQUERADE.
# ------------------------------------------------------------
log "3. Manteniendo las VLAN sin salida a Internet"

echo ">> No se configura NAT/MASQUERADE."
echo ">> La interfaz ens3 no se habilita como salida de las VLAN."

# ------------------------------------------------------------
# 4. Sin ruteo entre VLANs
#
# No se ejecuta el script routing_networks.sh.
# Las redes permanecen aisladas entre si.
# ------------------------------------------------------------
log "4. Manteniendo aislamiento entre VLAN 100 y VLAN 200"

echo ">> No se configura ruteo entre las VLANs."
echo ">> VLAN 100 <-> VLAN 200 -> AISLADAS"

# ------------------------------------------------------------
# 5. Sin reglas adicionales de IPTABLES
#
# No se agregan reglas FORWARD para permitir:
#   - VLAN100 -> VLAN200
#   - VLAN200 -> VLAN100
#   - VLAN100 -> ens3
#   - VLAN200 -> ens3
#
# Se conserva la politica FORWARD DROP configurada por el script init_master.sh.
# ------------------------------------------------------------
log "5. Verificando aislamiento mediante IPTABLES"

ssh "${SSH_USER}@${SERVER3}" '
set -e

echo ">> Politica actual de FORWARD:"
sudo iptables -L FORWARD -n -v --line-numbers

echo
echo ">> Tabla NAT (no debe existir MASQUERADE de estas VLAN):"
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
'

# ------------------------------------------------------------
# 6. Crear los contenedores en Server1 y obtener IP por DHCP
#
# Los contenedores se conectan a sus respectivas VLAN y luego
# solicitan direccion IP mediante el comando udhcpc.
# ------------------------------------------------------------
log "6. Creando contenedores en Server1 con DHCP"

ssh "${SSH_USER}@${SERVER1}" 'bash -s' <<REMOTE_CONTAINERS
set -e

create_container_dhcp() {
    local name="\$1"
    local ovs_port="\$2"
    local container_veth="\$3"
    local vlan="\$4"

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

    echo ">> Solicitando direccion DHCP para \$name..."
    sudo nsenter -t "\$PID" -n udhcpc -i eth1 -q

    echo "\$name conectado a VLAN \$vlan."
    echo "  Direccionamiento obtenido por DHCP:"
    sudo nsenter -t "\$PID" -n ip -br addr show eth1
    echo "  Rutas:"
    sudo nsenter -t "\$PID" -n ip route
}

create_container_dhcp \
    container_vlan100 \
    veth_ovs \
    veth_container \
    100

create_container_dhcp \
    container_vlan200 \
    veth_ovs_200 \
    veth_cont_200 \
    200
REMOTE_CONTAINERS

# ------------------------------------------------------------
# 7. Crear las dos VMs en Server2
#
# El script create_vm.sh conserva los 4 parametros de entrada
# Las VMs se conectan a sus respectivas VLAN.
#
# MAC:
#   VLAN100 -> 20:18:27:58:01:00
#   VLAN200 -> 20:18:27:58:02:00
#
# El direccionamiento del guest se obtiene por DHCP desde
# los servidores dnsmasq de Server3.
# ------------------------------------------------------------
log "7. Creando VMs en Server2"

echo ">> VM VLAN 100 -> DHCP -> MAC 20:18:27:58:01:00"
run_remote_script "$SERVER2" "$ROOT_DIR/create_vm.sh" \
    vm_vlan100 br-int "$VLAN100" "$VNC100"

echo ">> VM VLAN 200 -> DHCP -> MAC 20:18:27:58:02:00"
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
echo "[Direccionamiento DHCP de los contenedores]"
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
echo "[Namespaces DHCP]"
sudo ip netns list | grep "ns-dhcp-vlan" || true
echo
echo "[DHCP VLAN 100]"
sudo ip netns exec ns-dhcp-vlan100 ip -br addr 2>/dev/null || true
echo
echo "[DHCP VLAN 200]"
sudo ip netns exec ns-dhcp-vlan200 ip -br addr 2>/dev/null || true
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

log "DESPLIEGUE DE TOPOLOGIA 3 FINALIZADO"

echo "Topologia desplegada:"
echo "  VLAN 100 -> 192.168.0.0/24 -> DHCP -> SIN Internet"
echo "  VLAN 200 -> 192.168.2.0/24 -> DHCP -> SIN Internet"
echo "  Server1 -> contenedores con direccionamiento DHCP"
echo "  Server2 -> VMs conectadas a las VLAN y preparadas para DHCP"
echo "  Server3 -> gateways + DHCP independiente por VLAN"
echo "  VLAN 100 <-> VLAN 200 -> AISLADAS"
echo "  NAT -> NO CONFIGURADO"
echo "  Ruteo inter-VLAN -> NO CONFIGURADO"
echo
echo "Rangos DHCP:"
echo "  VLAN 100 -> ${DHCP_RANGE100}"
echo "  VLAN 200 -> ${DHCP_RANGE200}"
echo
echo "MAC de las VMs:"
echo "  vm_vlan100 -> 20:18:27:58:01:00"
echo "  vm_vlan200 -> 20:18:27:58:02:00"