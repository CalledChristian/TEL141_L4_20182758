#!/bin/bash

# Validamos si se ingresó los parametros de entrada requeridos: nombre de VM , bridge ovs , VLAN ID , y puerto VNC , al ejecutar el script
if [ "$#" -ne 4 ]; then
    echo "Error: Debe indicar el nombre de la VM, el bridge OVS, el ID de VLAN y el puerto VNC."
    echo "Ejm: ./create_vm.sh vm_vlan100 br-int 100 5901"
    exit 1
fi

VM_NAME="$1"
OVS_NAME="$2"
VLAN_ID="$3"
VNC_PORT="$4"

BASE_IMAGE="cirros-0.5.1-x86_64-disk.img"
VM_IMAGE="${VM_NAME}_img.qcow2"
TAP_NAME="${VM_NAME}_tap"

# Descargamos la imagen base si no se encuentra en el servidor
if [ ! -f "$BASE_IMAGE" ]; then

    echo "Imagen base no encontrada."
    echo "Descargando $BASE_IMAGE..."

    wget -c \
        https://download.cirros-cloud.net/0.5.1/cirros-0.5.1-x86_64-disk.img

    if [ $? -ne 0 ]; then
        echo "Error: No se pudo descargar la imagen base."
        exit 1
    fi
fi

# Verificamos si la VM ya existe
if [ -f "$VM_IMAGE" ]; then
    echo "Error: Ya existe la imagen de la VM $VM_IMAGE."
    echo "Elimine primero la VM antes de crearla nuevamente."
    exit 1
fi

# Creamos el disco diferencial
qemu-img create \
    -f qcow2 \
    -b "$BASE_IMAGE" \
    -F qcow2 \
    "$VM_IMAGE"

# Creamos la interfaz TAP
if ! ip link show "$TAP_NAME" >/dev/null 2>&1; then
    sudo ip tuntap add mode tap name "$TAP_NAME"
fi

# Levantamos la interfaz TAP
sudo ip link set "$TAP_NAME" up

# Conectamos la interfaz TAP al bridge ovs 
sudo ovs-vsctl add-port "$OVS_NAME" "$TAP_NAME"

# Configuramos la VLAN
sudo ovs-vsctl set port "$TAP_NAME" tag="$VLAN_ID"

echo "TAP $TAP_NAME conectado a $OVS_NAME."
echo "VLAN configurada: $VLAN_ID"

# Generamos una MAC basada en VLAN (en este caso, uso mi código PUCP : 20182758 , al inicio de la MAC)
# Manteniendo el esquema de MAC utilizado en el Lab 3:
#   VM VLAN 100 -> 20:18:27:58:01:00
#   VM VLAN 200 -> 20:18:27:58:02:00
case "$VLAN_ID" in
    100) MAC_VLAN="01" ;;
    200) MAC_VLAN="02" ;;
    *)
        echo "Error: VLAN $VLAN_ID no soportada para la MAC de esta práctica"
        exit 1
        ;;
esac

MAC="20:18:27:58:${MAC_VLAN}:00"

# Iniciamos la VM con QEMU - KVM
sudo qemu-system-x86_64 \
    -enable-kvm \
    -vnc 0.0.0.0:$((VNC_PORT - 5900)) \
    -netdev tap,id="$TAP_NAME",ifname="$TAP_NAME",script=no,downscript=no \
    -device e1000,netdev="$TAP_NAME",mac="$MAC" \
    -daemonize \
    "$VM_IMAGE"

echo "VM creada correctamente."
echo "Nombre: $VM_NAME"
echo "Imagen: $VM_IMAGE"
echo "TAP: $TAP_NAME"
echo "VLAN: $VLAN_ID"
echo "VNC: $VNC_PORT"