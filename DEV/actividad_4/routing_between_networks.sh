#!/bin/bash
set -euo pipefail

# ============================================================
# Actividad 4: Enrutamiento entre redes aisladas
#
# Actividad incremental sobre la topologia de Actividad 3:
#   - VLAN 100 + DHCP + sin Internet
#   - VLAN 200 + DHCP + sin Internet
#   - Se agrega UNICAMENTE ruteo entre las VLANs de la topologia de actividad 3
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
VLAN200="200"
NET100="192.168.0.0/24"
NET200="192.168.2.0/24"
GW100="192.168.0.1"
GW200="192.168.2.1"

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
        "${SSH_USER}@${host}" hostname >/dev/null
}

# ------------------------------------------------------------
# 0. SSH desde Server4
# ------------------------------------------------------------
log "0. Verificando acceso SSH desde Server4"
check_ssh "$SERVER1"
check_ssh "$SERVER2"
check_ssh "$SERVER3"

# ------------------------------------------------------------
# 1. Verificar que exista la topologia de Actividad 3
# ------------------------------------------------------------
log "1. Verificando la topologia desplegada en la Actividad 3"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<REMOTE_VERIFY
set -e

echo ">> Verificando bridge OVS br-int..."
sudo ovs-vsctl br-exists br-int

echo ">> Verificando gateway VLAN 100..."
ip link show gw_vlan100 >/dev/null
ip -4 addr show gw_vlan100 | grep -q "${GW100}/24"

echo ">> Verificando gateway VLAN 200..."
ip link show gw_vlan200 >/dev/null
ip -4 addr show gw_vlan200 | grep -q "${GW200}/24"

echo ">> Verificando DHCP VLAN 100..."
sudo ip netns list | grep -q "ns-dhcp-vlan100"

echo ">> Verificando DHCP VLAN 200..."
sudo ip netns list | grep -q "ns-dhcp-vlan200"

echo ">> Verificando forwarding IPv4..."
test "\$(sysctl -n net.ipv4.ip_forward)" = "1"

echo ">> Topologia de Actividad 3 encontrada correctamente."
REMOTE_VERIFY

# ------------------------------------------------------------
# 2. IPTABLES 1: habilitar ruteo entre VLANs
# ------------------------------------------------------------
log "2. Habilitando IPTABLES 1: ruteo entre VLANs"

run_remote_script "$SERVER3" "$ROOT_DIR/routing_networks.sh" \
    "$VLAN100" "$VLAN200"

# ------------------------------------------------------------
# 3. Mantener sin salida a Internet
# ------------------------------------------------------------
log "3. Verificando que la salida a Internet permanezca deshabilitada"

ssh "${SSH_USER}@${SERVER3}" '
echo ">> Tabla NAT actual:"
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
echo
echo ">> No se ejecuta internet_to_network.sh."
echo ">> No se agrega MASQUERADE."
'

echo ">> IPTABLES 1: RUTEO INTER-VLAN ACTIVO"
REMOTE_RULES

# ------------------------------------------------------------
# 4. Verificar las reglas de ruteo
# ------------------------------------------------------------
log "4. Verificando IPTABLES 1"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<REMOTE_RULES
set -e

echo ">> Tabla FORWARD:"
sudo iptables -L FORWARD -n -v --line-numbers

echo
echo ">> Verificando VLAN 100 -> VLAN 200..."
sudo iptables -C FORWARD -i gw_vlan100 -o gw_vlan200 -j ACCEPT

echo ">> Verificando VLAN 200 -> VLAN 100..."
sudo iptables -C FORWARD -i gw_vlan200 -o gw_vlan100 -j ACCEPT

echo
echo ">> IPTABLES 1: RUTEO INTER-VLAN ACTIVO"
REMOTE_RULES

# ------------------------------------------------------------
# 5. Verificar gateways y DHCP
# ------------------------------------------------------------
log "5. Verificando gateways y servicios DHCP"

ssh "${SSH_USER}@${SERVER3}" '
echo "----- Gateways -----"
ip -br addr show gw_vlan100 gw_vlan200

echo
echo "----- Namespaces DHCP -----"
sudo ip netns list | grep "ns-dhcp-vlan" || true

echo
echo "----- DHCP VLAN 100 -----"
sudo ip netns exec ns-dhcp-vlan100 ip -br addr 2>/dev/null || true

echo
echo "----- DHCP VLAN 200 -----"
sudo ip netns exec ns-dhcp-vlan200 ip -br addr 2>/dev/null || true
'

# ------------------------------------------------------------
# 6. Verificar endpoints existentes de Topologia 3
# ------------------------------------------------------------
log "6. Verificando endpoints de las VLAN"

echo "----- Server1: contenedores -----"
ssh "${SSH_USER}@${SERVER1}" '
for c in container_vlan100 container_vlan200; do
    echo "### $c"
    if docker ps --format "{{.Names}}" | grep -qx "$c"; then
        PID=$(docker inspect -f "{{.State.Pid}}" "$c")
        sudo nsenter -t "$PID" -n ip -br addr
        echo "Rutas:"
        sudo nsenter -t "$PID" -n ip route
    else
        echo "Contenedor no encontrado: $c"
    fi
done
'

echo
echo "----- Server2: VMs -----"
ssh "${SSH_USER}@${SERVER2}" '
echo "[TAP]"
ip -br link show vm_vlan100_tap vm_vlan200_tap 2>/dev/null || true
echo
echo "[QEMU]"
pgrep -af "qemu-system-x86_64.*vm_vlan" || true
'

# ------------------------------------------------------------
# 7. Prueba de conectividad inter-VLAN desde contenedores
# ------------------------------------------------------------
log "7. Probando conectividad inter-VLAN"

ssh "${SSH_USER}@${SERVER1}" 'bash -s' <<REMOTE_TEST
set +e

for c in container_vlan100 container_vlan200; do
    if ! docker ps --format "{{.Names}}" | grep -qx "\$c"; then
        echo "Contenedor \$c no disponible; se omite prueba."
        continue
    fi

    PID=\$(docker inspect -f "{{.State.Pid}}" "\$c")
    echo
    echo "### \$c"

    if [ "\$c" = "container_vlan100" ]; then
        echo ">> VLAN 100 -> Gateway VLAN 200 (${GW200})"
        sudo nsenter -t "\$PID" -n ping -c 3 -W 2 "${GW200}"
    else
        echo ">> VLAN 200 -> Gateway VLAN 100 (${GW100})"
        sudo nsenter -t "\$PID" -n ping -c 3 -W 2 "${GW100}"
    fi
done

exit 0
REMOTE_TEST

# ------------------------------------------------------------
# 8. Resultado final
# ------------------------------------------------------------
log "ENRUTAMIENTO ENTRE VLANS DE TOPOLOGIA 3 FINALIZADO"

echo "Topologia resultante:"
echo "  VLAN 100 -> ${NET100} -> DHCP -> SIN Internet"
echo "  VLAN 200 -> ${NET200} -> DHCP -> SIN Internet"
echo
echo "Cambio realizado:"
echo "  VLAN 100 <-> VLAN 200 -> CON ENRUTAMIENTO"
echo
echo "Server3:"
echo "  ${GW100} -> VLAN 100"
echo "  ${GW200} -> VLAN 200"
echo
echo "IPTABLES 1 -> Ruteo entre VLANs: ACTIVADO"
echo "IPTABLES 2 -> Salida a Internet: NO CONFIGURADA"
echo
