#!/bin/bash

set -euo pipefail

# ============================================================
# TEL141 - Laboratorio 4
# delete_topology.sh
#
# Elimina una topologia previamente desplegada desde Server4.
#
# Uso:
#   ./delete_topology.sh <n* de topologia>
# Ejm:
#   ./delete_topology.sh 1
#
# Topologia 1:
#   DHCP + Internet + ruteo inter-VLAN
#
# Topologia 2:
#   Sin DHCP + Internet + ruteo inter-VLAN
#
# Topologia 3:
#   DHCP + sin Internet + ruteo inter-VLAN
#   (Actividades 3 + 4)
#
# IMPORTANTE:
#   Server1, Server2 y Server3 quedan preparados para levantar
#   una nueva topologia.
#
# NO se eliminan las interfaces fisicas ens3/ens4 ni docker0.
# ============================================================

if [ "$#" -ne 1 ]; then
    echo "Uso: $0 {1|2|3}"
    echo
    echo "  1 -> Eliminar Topologia 1"
    echo "  2 -> Eliminar Topologia 2"
    echo "  3 -> Eliminar Topologia 3 (Actividades 3 + 4)"
    exit 1
fi

TOPOLOGY="$1"

case "$TOPOLOGY" in
    1)
        TOPOLOGY_NAME="Topologia 1: DHCP + Internet + ruteo"
        REMOVE_NAT="yes"
        REMOVE_ROUTING="yes"
        ;;
    2)
        TOPOLOGY_NAME="Topologia 2: sin DHCP + Internet + ruteo"
        REMOVE_NAT="yes"
        REMOVE_ROUTING="yes"
        ;;
    3)
        TOPOLOGY_NAME="Topologia 3: DHCP + sin Internet + ruteo (Actividades 3 + 4)"
        REMOVE_NAT="no"
        REMOVE_ROUTING="yes"
        ;;
    *)
        echo "Error: Topologia no valida."
        echo "Valores permitidos: 1, 2 o 3."
        exit 1
        ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVER1="10.0.10.1"
SERVER2="10.0.10.2"
SERVER3="10.0.10.3"
SSH_USER="ubuntu"

VLAN100="100"
NET100="192.168.0.0/24"
VLAN200="200"
NET200="192.168.2.0/24"

OVS="br-int"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

check_ssh() {
    local host="$1"

    echo ">> Verificando SSH con $host..."
    ssh -o BatchMode=yes -o ConnectTimeout=5 \
        "${SSH_USER}@${host}" hostname >/dev/null
}

run_remote_script() {
    local host="$1"
    local script="$2"
    shift 2

    echo ">> Ejecutando $(basename "$script") en $host..."
    ssh "${SSH_USER}@${host}" 'bash -s' < "$script" "$@"
}

# ------------------------------------------------------------
# 0. Verificacion de acceso
# ------------------------------------------------------------
log "0. Verificando acceso SSH desde Server4"

check_ssh "$SERVER1"
check_ssh "$SERVER2"
check_ssh "$SERVER3"

echo
echo ">> Topologia seleccionada:"
echo "   $TOPOLOGY_NAME"

# ------------------------------------------------------------
# 1. Eliminar VMs de Server2
# ------------------------------------------------------------
log "1. Eliminando VMs de Server2"

# delete_vm.sh se utiliza para conservar el modulo proporcionado
# en el laboratorio.
#
# Si una VM no existe, el modulo informa que no encontro QEMU y
# continua con la eliminacion de TAP/imagen si existen.
run_remote_script "$SERVER2" "$ROOT_DIR/delete_vm.sh" \
    vm_vlan100 "$OVS" "$VLAN100" 5901 || true

run_remote_script "$SERVER2" "$ROOT_DIR/delete_vm.sh" \
    vm_vlan200 "$OVS" "$VLAN200" 5902 || true

# ------------------------------------------------------------
# 2. Eliminar contenedores de Server1
# ------------------------------------------------------------
log "2. Eliminando contenedores de Server1"

ssh "${SSH_USER}@${SERVER1}" 'bash -s' <<'REMOTE_CONTAINERS'
set +e

for container in container_vlan100 container_vlan200; do
    echo ">> Eliminando $container..."

    if docker ps -a --format "{{.Names}}" | grep -qx "$container"; then
        docker rm -f "$container"
        echo "   $container eliminado."
    else
        echo "   $container no existe."
    fi
done

# Por seguridad, eliminamos cualquier veth residual de los
# contenedores si aun apareciera en el host.
for iface in veth_ovs veth_container veth_ovs_200 veth_cont_200; do
    if ip link show "$iface" >/dev/null 2>&1; then
        echo ">> Eliminando interfaz residual $iface..."
        sudo ip link delete "$iface" 2>/dev/null || true
    fi
done

exit 0
REMOTE_CONTAINERS

# ------------------------------------------------------------
# 3. Eliminar reglas de IPTABLES
#
# Topologias 1 y 2:
#   - NAT VLAN100/VLAN200
#   - ruteo VLAN100 <-> VLAN200
#   - reglas FORWARD hacia ens3
#   - regla RELATED,ESTABLISHED
#
# Topologia 3:
#   - no hay NAT
#   - se elimina el ruteo agregado por Actividad 4
# ------------------------------------------------------------
log "3. Eliminando reglas IPTABLES de la topologia"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<REMOTE_FIREWALL
set +e

echo ">> Eliminando reglas especificas de la topologia..."

if [ "${REMOVE_ROUTING}" = "yes" ]; then
    if sudo iptables -C FORWARD -i gw_vlan100 -o gw_vlan200 -j ACCEPT 2>/dev/null &&
       sudo iptables -C FORWARD -i gw_vlan200 -o gw_vlan100 -j ACCEPT 2>/dev/null; then
        echo ">> Eliminando ruteo inter-VLAN mediante no_routing_networks.sh..."
        # El modulo se ejecuta despues desde Server4.
    else
        echo ">> No se encontraron ambas reglas de ruteo; se continua."
    fi
fi

# Eliminar las reglas FORWARD hacia Internet que agregaron
# las topologias 1 y 2.
if [ "${REMOVE_NAT}" = "yes" ]; then

    while sudo iptables -C FORWARD -i gw_vlan100 -o ens3 -j ACCEPT 2>/dev/null; do
        sudo iptables -D FORWARD -i gw_vlan100 -o ens3 -j ACCEPT
    done

    while sudo iptables -C FORWARD -i gw_vlan200 -o ens3 -j ACCEPT 2>/dev/null; do
        sudo iptables -D FORWARD -i gw_vlan200 -o ens3 -j ACCEPT
    done

    while sudo iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
        sudo iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    done

    echo ">> Reglas FORWARD de salida a Internet eliminadas."
fi

exit 0
REMOTE_FIREWALL

# Ejecutamos los modulos de eliminacion solo cuando las reglas
# correspondientes existen. Esto evita que un iptables -D
# inexistente detenga el proceso.
if [ "$REMOVE_ROUTING" = "yes" ]; then
    ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<'REMOTE_ROUTING'
set +e

if sudo iptables -C FORWARD -i gw_vlan100 -o gw_vlan200 -j ACCEPT 2>/dev/null &&
   sudo iptables -C FORWARD -i gw_vlan200 -o gw_vlan100 -j ACCEPT 2>/dev/null; then
    exit 0
fi

# Si solo una regla existe, se elimina directamente para dejar
# el estado limpio.
while sudo iptables -C FORWARD -i gw_vlan100 -o gw_vlan200 -j ACCEPT 2>/dev/null; do
    sudo iptables -D FORWARD -i gw_vlan100 -o gw_vlan200 -j ACCEPT
done

while sudo iptables -C FORWARD -i gw_vlan200 -o gw_vlan100 -j ACCEPT 2>/dev/null; do
    sudo iptables -D FORWARD -i gw_vlan200 -o gw_vlan100 -j ACCEPT
done

exit 0
REMOTE_ROUTING

    # Usamos el modulo solicitado cuando ambas reglas estan
    # presentes en la topologia.
    if ssh "${SSH_USER}@${SERVER3}" \
        'sudo iptables -C FORWARD -i gw_vlan100 -o gw_vlan200 -j ACCEPT 2>/dev/null &&
         sudo iptables -C FORWARD -i gw_vlan200 -o gw_vlan100 -j ACCEPT 2>/dev/null'; then
        run_remote_script "$SERVER3" "$ROOT_DIR/no_routing_networks.sh" \
            "$VLAN100" "$VLAN200"
    else
        echo ">> Las reglas de ruteo ya fueron eliminadas o no existian."
    fi
fi

if [ "$REMOVE_NAT" = "yes" ]; then
    # VLAN100
    if ssh "${SSH_USER}@${SERVER3}" \
        "sudo iptables -t nat -C POSTROUTING -s ${NET100} -o ens3 -j MASQUERADE 2>/dev/null"; then
        run_remote_script "$SERVER3" "$ROOT_DIR/no_internet_to_network.sh" \
            "$VLAN100" "$NET100"
    else
        echo ">> NAT VLAN 100 no encontrado."
    fi

    # VLAN200
    if ssh "${SSH_USER}@${SERVER3}" \
        "sudo iptables -t nat -C POSTROUTING -s ${NET200} -o ens3 -j MASQUERADE 2>/dev/null"; then
        run_remote_script "$SERVER3" "$ROOT_DIR/no_internet_to_network.sh" \
            "$VLAN200" "$NET200"
    else
        echo ">> NAT VLAN 200 no encontrado."
    fi
fi

# ------------------------------------------------------------
# 4. Eliminar DHCP de Server3
#
# Esto aplica a las topologias 1 y 3.
# La operacion es segura tambien si los namespaces no existen.
# ------------------------------------------------------------
log "4. Eliminando servicios DHCP de Server3"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<'REMOTE_DHCP'
set +e

for ns in ns-dhcp-vlan100 ns-dhcp-vlan200; do
    echo ">> Procesando namespace $ns..."

    if sudo ip netns list | grep -q "^$ns"; then
        echo "   Deteniendo dnsmasq..."
        sudo ip netns exec "$ns" pkill dnsmasq 2>/dev/null || true

        echo "   Eliminando namespace..."
        sudo ip netns del "$ns" 2>/dev/null || true
    else
        echo "   Namespace $ns no existe."
    fi
done

# Eliminar puertos DHCP residuales de OVS si aun existen.
for port in dhcp_v100 dhcp_v200; do
    if sudo ovs-vsctl list-ports br-int 2>/dev/null | grep -qx "$port"; then
        echo ">> Eliminando puerto OVS residual $port..."
        sudo ovs-vsctl del-port br-int "$port" 2>/dev/null || true
    fi
done

exit 0
REMOTE_DHCP

# ------------------------------------------------------------
# 5. Eliminar puertos/gateways VLAN de Server3
# ------------------------------------------------------------
log "5. Eliminando gateways VLAN de Server3"

ssh "${SSH_USER}@${SERVER3}" 'bash -s' <<'REMOTE_GATEWAYS'
set +e

for port in gw_vlan100 gw_vlan200; do
    if sudo ovs-vsctl list-ports br-int 2>/dev/null | grep -qx "$port"; then
        echo ">> Eliminando puerto OVS $port..."
        sudo ovs-vsctl del-port br-int "$port" 2>/dev/null || true
    fi

    if ip link show "$port" >/dev/null 2>&1; then
        sudo ip link delete "$port" 2>/dev/null || true
    fi
done

exit 0
REMOTE_GATEWAYS

# ------------------------------------------------------------
# 6. Eliminar br-int de Server1, Server2 y Server3
#
# Al eliminar el bridge OVS:
#   - se desconecta ens4 del bridge
#   - se eliminan los puertos virtuales asociados
#
# NO se elimina la interfaz fisica ens4.
# NO se toca ens3.
# NO se toca docker0.
# ------------------------------------------------------------
log "6. Eliminando bridges OVS de la topologia"

for server in "$SERVER1" "$SERVER2" "$SERVER3"; do
    echo ">> Limpiando OVS en $server..."

    ssh "${SSH_USER}@${server}" 'bash -s' <<'REMOTE_OVS'
set +e

if sudo ovs-vsctl br-exists br-int 2>/dev/null; then
    echo "   Eliminando bridge br-int..."
    sudo ovs-vsctl del-br br-int
else
    echo "   br-int no existe."
fi

# Aseguramos que las interfaces fisicas sigan existiendo.
ip link show ens3 >/dev/null 2>&1 && echo "   ens3 preservada."
ip link show ens4 >/dev/null 2>&1 && echo "   ens4 preservada."

exit 0
REMOTE_OVS
done

# ------------------------------------------------------------
# 7. Restablecer forwarding del Server3
#
# init_master.sh habia establecido:
#   net.ipv4.ip_forward=1
#   iptables -P FORWARD DROP
#
# Dejamos la politica FORWARD en DROP para no dejar reglas
# abiertas residuales. El siguiente despliegue vuelve a ejecutar
# init_master.sh.
# ------------------------------------------------------------
log "7. Dejando el firewall en estado base"

ssh "${SSH_USER}@${SERVER3}" '
sudo iptables -P FORWARD DROP
sudo sysctl -w net.ipv4.ip_forward=0 >/dev/null
echo ">> Politica FORWARD: DROP"
echo ">> IPv4 forwarding: deshabilitado"
'

# ------------------------------------------------------------
# 8. Verificacion final
# ------------------------------------------------------------
log "8. Verificando que la topologia haya sido eliminada"

echo "----- Server1 -----"
ssh "${SSH_USER}@${SERVER1}" '
echo "[OVS]"
sudo ovs-vsctl show
echo
echo "[Contenedores VLAN]"
docker ps -a --format "{{.Names}}" | grep -E "^container_vlan(100|200)$" || echo "Sin contenedores VLAN."
echo
echo "[Interfaces fisicas]"
ip -br link show ens3 ens4
'

echo
echo "----- Server2 -----"
ssh "${SSH_USER}@${SERVER2}" '
echo "[OVS]"
sudo ovs-vsctl show
echo
echo "[TAP]"
ip link show vm_vlan100_tap >/dev/null 2>&1 && echo "vm_vlan100_tap aun existe" || echo "vm_vlan100_tap eliminado."
ip link show vm_vlan200_tap >/dev/null 2>&1 && echo "vm_vlan200_tap aun existe" || echo "vm_vlan200_tap eliminado."
echo
echo "[QEMU]"
pgrep -af "qemu-system-x86_64.*vm_vlan" || echo "Sin procesos QEMU de las VLAN."
echo
echo "[Interfaces fisicas]"
ip -br link show ens3 ens4
'

echo
echo "----- Server3 -----"
ssh "${SSH_USER}@${SERVER3}" '
echo "[OVS]"
sudo ovs-vsctl show
echo
echo "[Gateways]"
ip link show gw_vlan100 >/dev/null 2>&1 && echo "gw_vlan100 aun existe" || echo "gw_vlan100 eliminado."
ip link show gw_vlan200 >/dev/null 2>&1 && echo "gw_vlan200 aun existe" || echo "gw_vlan200 eliminado."
echo
echo "[Namespaces DHCP]"
sudo ip netns list | grep "ns-dhcp-vlan" || echo "Sin namespaces DHCP de la topologia."
echo
echo "[iptables FORWARD]"
sudo iptables -L FORWARD -n -v --line-numbers
echo
echo "[iptables NAT]"
sudo iptables -t nat -L POSTROUTING -n -v --line-numbers
echo
echo "[Interfaces fisicas]"
ip -br link show ens3 ens4
'

log "ELIMINACION DE TOPOLOGIA FINALIZADA"

echo "Topologia eliminada:"
echo "  $TOPOLOGY_NAME"
echo
echo "Recursos de la topologia removidos:"
echo "  - VMs"
echo "  - contenedores"
echo "  - TAPs"
echo "  - gateways VLAN"
echo "  - namespaces DHCP"
echo "  - puertos OVS"
echo "  - bridge br-int"
echo "  - reglas IPTABLES correspondientes"
echo
echo "Interfaces preservadas:"
echo "  - ens3"
echo "  - ens4"
echo "  - docker0 (Server1)"
echo
echo "Server1, Server2 y Server3 quedan listos para desplegar"
echo "la siguiente topologia."
