#!/bin/bash

# Validamos si se ingresó al menos uno o más interfaces de red al ejecutar el script
if [ "$#" -lt 1 ]; then
    echo "Error: Debe indicar al menos una interfaz de red."
    echo "Ejm: ./init_master.sh ens4"
    echo "También puede indicar varias interfaces: ./init_master.sh ens4 ens5 ...."
    exit 1
fi

# Creamos el bridge ovs br-int si no existe
if ! sudo ovs-vsctl br-exists br-int; then
    sudo ovs-vsctl add-br br-int
fi

# Conectamos las interfaces al bridge br-int
for interface in "$@"; do
    sudo ovs-vsctl add-port br-int "$interface"
    sudo ip link set "$interface" up
done

# Habilitamos IPv4 forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# Configuramos la política FOWARD de iptables en DROP
sudo iptables -P FORWARD DROP

echo "Master inicializado correctamente."
echo "Bridge OVS: br-int"
echo "IPv4 forwarding: habilitado"
echo "Política FORWARD iptables: DROP"