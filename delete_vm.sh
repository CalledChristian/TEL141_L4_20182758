#!/bin/bash

# Validamos si se ingresó los parametros de entrada requeridos: nombre de VM , bridge ovs , VLAN ID , y puerto VNC , al ejecutar el script
if [ "$#" -ne 4 ]; then
    echo "Error: Debe indicar el nombre de la VM, el bridge OVS, el ID de VLAN y el puerto VNC."
    echo "Ejm: ./delete_vm.sh vm_vlan100 br-int 100 5901"
    exit 1
fi

VM_NAME="$1"
OVS_NAME="$2"
VLAN_ID="$3"
VNC_PORT="$4"

VM_IMAGE="${VM_NAME}_img.qcow2"
TAP_NAME="${VM_NAME}_tap"

# Buscamos el proceso QEMU asociado a la VM e imagen utilizada
PID=$(pgrep -f "qemu-system-x86_64.*${VM_IMAGE}")

# Eliminamos el proceso QEMU asociado a la VM
if [ -n "$PID" ]; then
    echo "Deteniendo VM $VM_NAME..."
    sudo kill "$PID"
    sleep 2
else
    echo "No se encontró un proceso QEMU para $VM_NAME."
fi

# Eliminamos el puerto TAP del bridge ovs
if sudo ovs-vsctl list-ports "$OVS_NAME" | grep -q "^${TAP_NAME}$"; then
    sudo ovs-vsctl del-port "$OVS_NAME" "$TAP_NAME"
fi

# Eliminamos la interfaz TAP
if ip link show "$TAP_NAME" >/dev/null 2>&1; then
    sudo ip link delete "$TAP_NAME"
fi

# Eliminamos la imagen diferencial
if [ -f "$VM_IMAGE" ]; then
    rm -f "$VM_IMAGE"
fi

echo "VM eliminada correctamente."
echo "Nombre: $VM_NAME"
echo "VLAN: $VLAN_ID"
echo "Puerto VNC: $VNC_PORT"