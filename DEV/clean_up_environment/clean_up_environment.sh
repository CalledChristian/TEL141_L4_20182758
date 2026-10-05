#!/bin/bash

# ============================================================
# clean_up_environment.sh : 
# Limpia los recursos utilizados por la topología del Lab 3
# en Server 1, Server 2 y Server 3.
#
# Este script se ejecuta desde Server 4.
#
# IMPORTANTE:
#   ens3 = Management  -> NO SE ELIMINA
#   ens4 = Data Network -> NO SE ELIMINA
#
# El script elimina únicamente los recursos conocidos de la
# topología desplegada en el Laboratorio 3 , para tener 
# los servidores limpios para desplegar cada topologia requerida.
# ============================================================


# ============================================================
# CONFIGURACIÓN
# ============================================================

SSH_USER="ubuntu"

SERVER1="10.0.10.1"
SERVER2="10.0.10.2"
SERVER3="10.0.10.3"


# ============================================================
# FUNCIÓN PARA EJECUTAR COMANDOS REMOTOS
# ============================================================

run_remote()
{
    local SERVER="$1"
    local SCRIPT="$2"

    echo ""
    echo "============================================================"
    echo "Conectando con $SERVER"
    echo "============================================================"

    #NOTA: SSH PASSWORDLESS CONFIGURADO PREVIAMENTE DESDE SERVER 4 A LOS SERVERS 1, 2 y 3
    ssh "$SSH_USER@$SERVER" 'bash -s' <<< "$SCRIPT"

    if [ $? -ne 0 ]; then
        echo ""
        echo "Error: La limpieza de $SERVER presentó un problema."
        return 1
    fi

    return 0
}


# ============================================================
# SERVER 1
# ============================================================

SERVER1_SCRIPT='

echo ""
echo "============================================================"
echo "LIMPIEZA SERVER 1"
echo "============================================================"

echo ""
echo "1. Eliminando contenedores del Lab 3..."
echo "------------------------------------------------------------"

if docker ps -a --format "{{.Names}}" | grep -qx "container_vlan100"; then

    docker rm -f container_vlan100
    echo "container_vlan100 eliminado."

else

    echo "container_vlan100 no existe."

fi


if docker ps -a --format "{{.Names}}" | grep -qx "container_vlan200"; then

    docker rm -f container_vlan200
    echo "container_vlan200 eliminado."

else

    echo "container_vlan200 no existe."

fi


echo ""
echo "2. Eliminando puertos OVS del Lab 3..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    if ovs-vsctl list-ports br-int | grep -qx "veth_ovs"; then

        ovs-vsctl del-port br-int veth_ovs
        echo "veth_ovs eliminado de br-int."

    else

        echo "veth_ovs no existe en br-int."

    fi


    if ovs-vsctl list-ports br-int | grep -qx "veth_ovs_200"; then

        ovs-vsctl del-port br-int veth_ovs_200
        echo "veth_ovs_200 eliminado de br-int."

    else

        echo "veth_ovs_200 no existe en br-int."

    fi

else

    echo "br-int no existe."

fi


echo ""
echo "3. Eliminando interfaces veth..."
echo "------------------------------------------------------------"

if ip link show veth_ovs >/dev/null 2>&1; then

    ip link delete veth_ovs
    echo "veth_ovs eliminado."

else

    echo "veth_ovs ya no existe."

fi


if ip link show veth_ovs_200 >/dev/null 2>&1; then

    ip link delete veth_ovs_200
    echo "veth_ovs_200 eliminado."

else

    echo "veth_ovs_200 ya no existe."

fi


echo ""
echo "4. Eliminando bridge br-int..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    ovs-vsctl del-br br-int
    echo "br-int eliminado."

else

    echo "br-int ya no existe."

fi


echo ""
echo "5. Verificación Server 1"
echo "------------------------------------------------------------"

echo "Interfaces:"
ip -br link

echo ""
echo "Contenedores:"
docker ps -a --format "table {{.Names}}\t{{.Status}}"

echo ""
echo "Configuración OVS:"
ovs-vsctl show

'


# ============================================================
# SERVER 2
# ============================================================

SERVER2_SCRIPT='

echo ""
echo "============================================================"
echo "LIMPIEZA SERVER 2"
echo "============================================================"

echo ""
echo "1. Deteniendo las VMs del Lab 3..."
echo "------------------------------------------------------------"


# ------------------------------------------------------------
# VM VLAN 100
# ------------------------------------------------------------

PIDS=$(pgrep -f "qemu-system.*vm_vlan100_img.qcow2" || true)

if [ -n "$PIDS" ]; then

    echo "Deteniendo VM VLAN 100..."

    kill $PIDS
    sleep 2

else

    echo "VM VLAN 100 no está ejecutándose."

fi


# ------------------------------------------------------------
# VM VLAN 200
# ------------------------------------------------------------

PIDS=$(pgrep -f "qemu-system.*vm_vlan200_img.qcow2" || true)

if [ -n "$PIDS" ]; then

    echo "Deteniendo VM VLAN 200..."

    kill $PIDS
    sleep 2

else

    echo "VM VLAN 200 no está ejecutándose."

fi


echo ""
echo "2. Eliminando puertos TAP de OVS..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    if ovs-vsctl list-ports br-int | grep -qx "vm_vlan100_tap"; then

        ovs-vsctl del-port br-int vm_vlan100_tap
        echo "vm_vlan100_tap eliminado de br-int."

    else

        echo "vm_vlan100_tap no existe en br-int."

    fi


    if ovs-vsctl list-ports br-int | grep -qx "vm_vlan200_tap"; then

        ovs-vsctl del-port br-int vm_vlan200_tap
        echo "vm_vlan200_tap eliminado de br-int."

    else

        echo "vm_vlan200_tap no existe en br-int."

    fi

else

    echo "br-int no existe."

fi


echo ""
echo "3. Eliminando interfaces TAP..."
echo "------------------------------------------------------------"

if ip link show vm_vlan100_tap >/dev/null 2>&1; then

    ip link delete vm_vlan100_tap
    echo "vm_vlan100_tap eliminado."

else

    echo "vm_vlan100_tap ya no existe."

fi


if ip link show vm_vlan200_tap >/dev/null 2>&1; then

    ip link delete vm_vlan200_tap
    echo "vm_vlan200_tap eliminado."

else

    echo "vm_vlan200_tap ya no existe."

fi


echo ""
echo "4. Eliminando imágenes diferenciales del Lab 3..."
echo "------------------------------------------------------------"

if [ -f vm_vlan100_img.qcow2 ]; then

    rm -f vm_vlan100_img.qcow2
    echo "vm_vlan100_img.qcow2 eliminado."

else

    echo "vm_vlan100_img.qcow2 no existe."

fi


if [ -f vm_vlan200_img.qcow2 ]; then

    rm -f vm_vlan200_img.qcow2
    echo "vm_vlan200_img.qcow2 eliminado."

else

    echo "vm_vlan200_img.qcow2 no existe."

fi


echo ""
echo "5. Eliminando bridge br-int..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    ovs-vsctl del-br br-int
    echo "br-int eliminado."

else

    echo "br-int ya no existe."

fi


echo ""
echo "6. Verificación Server 2"
echo "------------------------------------------------------------"

echo "Interfaces:"
ip -br link

echo ""
echo "Procesos QEMU:"
pgrep -af qemu-system || echo "No hay procesos QEMU activos."

echo ""
echo "Namespaces:"
ip netns list

echo ""
echo "Configuración OVS:"
ovs-vsctl show

'


# ============================================================
# SERVER 3
# ============================================================

SERVER3_SCRIPT='

echo ""
echo "============================================================"
echo "LIMPIEZA SERVER 3"
echo "============================================================"

echo ""
echo "1. Deteniendo DHCP del Lab 3..."
echo "------------------------------------------------------------"

if ip netns list | grep -q "ns-dhcp-vlan200"; then

    ip netns exec ns-dhcp-vlan200 pkill dnsmasq 2>/dev/null || true

    echo "Proceso dnsmasq detenido."

else

    echo "ns-dhcp-vlan200 no existe."

fi


echo ""
echo "2. Eliminando namespace DHCP..."
echo "------------------------------------------------------------"

if ip netns list | grep -q "ns-dhcp-vlan200"; then

    ip netns delete ns-dhcp-vlan200

    echo "ns-dhcp-vlan200 eliminado."

else

    echo "ns-dhcp-vlan200 ya no existe."

fi


echo ""
echo "3. Eliminando puerto DHCP del OVS..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    if ovs-vsctl list-ports br-int | grep -qx "dhcp_v200"; then

        ovs-vsctl del-port br-int dhcp_v200

        echo "dhcp_v200 eliminado de br-int."

    else

        echo "dhcp_v200 no existe en br-int."

    fi

else

    echo "br-int no existe."

fi


echo ""
echo "4. Eliminando gateways VLAN..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    if ovs-vsctl list-ports br-int | grep -qx "gw_vlan100"; then

        ovs-vsctl del-port br-int gw_vlan100

        echo "gw_vlan100 eliminado de br-int."

    else

        echo "gw_vlan100 no existe en br-int."

    fi


    if ovs-vsctl list-ports br-int | grep -qx "gw_vlan200"; then

        ovs-vsctl del-port br-int gw_vlan200

        echo "gw_vlan200 eliminado de br-int."

    else

        echo "gw_vlan200 no existe en br-int."

    fi

else

    echo "br-int no existe."

fi


echo ""
echo "5. Eliminando interfaces gateway..."
echo "------------------------------------------------------------"

if ip link show gw_vlan100 >/dev/null 2>&1; then

    ip link delete gw_vlan100

    echo "gw_vlan100 eliminado."

else

    echo "gw_vlan100 ya no existe."

fi


if ip link show gw_vlan200 >/dev/null 2>&1; then

    ip link delete gw_vlan200

    echo "gw_vlan200 eliminado."

else

    echo "gw_vlan200 ya no existe."

fi


echo ""
echo "6. Eliminando reglas FORWARD del Lab 3..."
echo "------------------------------------------------------------"

iptables -D FORWARD \
    -i gw_vlan100 \
    -o ens3 \
    -j ACCEPT 2>/dev/null || true

iptables -D FORWARD \
    -m conntrack \
    --ctstate RELATED,ESTABLISHED \
    -j ACCEPT 2>/dev/null || true

iptables -D FORWARD \
    -i gw_vlan100 \
    -o gw_vlan200 \
    -j ACCEPT 2>/dev/null || true

iptables -D FORWARD \
    -i gw_vlan200 \
    -o gw_vlan100 \
    -j ACCEPT 2>/dev/null || true

echo "Reglas FORWARD del Lab 3 procesadas."


echo ""
echo "7. Eliminando reglas NAT de las VLAN..."
echo "------------------------------------------------------------"

# Eliminar posibles reglas MASQUERADE de VLAN 100
while iptables -t nat -C POSTROUTING \
    -s 192.168.0.0/24 \
    -o ens3 \
    -j MASQUERADE 2>/dev/null; do

    iptables -t nat -D POSTROUTING \
        -s 192.168.0.0/24 \
        -o ens3 \
        -j MASQUERADE

done


# Eliminar posibles reglas MASQUERADE de VLAN 200
while iptables -t nat -C POSTROUTING \
    -s 192.168.2.0/24 \
    -o ens3 \
    -j MASQUERADE 2>/dev/null; do

    iptables -t nat -D POSTROUTING \
        -s 192.168.2.0/24 \
        -o ens3 \
        -j MASQUERADE

done

echo "Reglas NAT de las VLAN procesadas."


echo ""
echo "8. Eliminando bridge br-int..."
echo "------------------------------------------------------------"

if ovs-vsctl br-exists br-int; then

    ovs-vsctl del-br br-int

    echo "br-int eliminado."

else

    echo "br-int ya no existe."

fi


echo ""
echo "9. Verificación Server 3"
echo "------------------------------------------------------------"

echo "Interfaces:"
ip -br link

echo ""
echo "Namespaces:"
ip netns list

echo ""
echo "Configuración OVS:"
ovs-vsctl show

echo ""
echo "Reglas FORWARD:"
iptables -S FORWARD

echo ""
echo "Reglas NAT:"
iptables -t nat -S POSTROUTING

'


# ============================================================
# EJECUCIÓN
# ============================================================

echo ""
echo "#######################################"
echo "# INICIO DE LIMPIEZA DEL ENTORNO "
echo "#######################################"

echo ""
echo "IMPORTANTE:"
echo "  ens3 = Management   -> se conservará"
echo "  ens4 = Data Network -> se conservará"
echo ""


# ------------------------------------------------------------
# Server 1
# ------------------------------------------------------------

run_remote "$SERVER1" "$SERVER1_SCRIPT"

if [ $? -ne 0 ]; then
    echo "Error: La limpieza de Server 1 falló."
    exit 1
fi


# ------------------------------------------------------------
# Server 2
# ------------------------------------------------------------

run_remote "$SERVER2" "$SERVER2_SCRIPT"

if [ $? -ne 0 ]; then
    echo "Error: La limpieza de Server 2 falló."
    exit 1
fi


# ------------------------------------------------------------
# Server 3
# ------------------------------------------------------------

run_remote "$SERVER3" "$SERVER3_SCRIPT"

if [ $? -ne 0 ]; then
    echo "Error: La limpieza de Server 3 falló."
    exit 1
fi


# ============================================================
# FINAL
# ============================================================

echo ""
echo "#######################################"
echo "# LIMPIEZA COMPLETADA"
echo "#######################################"

echo ""
echo "Los recursos conocidos de la topología del Lab 3 fueron"
echo "eliminados."

echo ""
echo "Interfaces físicas conservadas:"
echo "  ens3 -> Management"
echo "  ens4 -> Data Network"

echo ""
echo "Los servidores están listos para el despliegue"
echo "automatizado de las topologias requeridas."