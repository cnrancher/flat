#!/bin/bash

set -ex

LABEL="io.rancher.network.l2flat.interface"
METADATA_ADDRESS=${RANCHER_METADATA_ADDRESS:-169.254.169.250}

while ! curl -s -f http://${METADATA_ADDRESS}/2016-07-29/self/host; do
    echo Waiting for metadata
    sleep 1
done

FLAT_IF_FROM_LABEL=$(curl -s http://${METADATA_ADDRESS}/2016-07-29/self/host/labels/${LABEL})

if [ "$(echo $FLAT_IF_FROM_LABEL | grep "Not found")" != ""  ]; then
    FLAT_IF=${FLAT_IF:-eth0}
else
    echo "Used the host label..."
    FLAT_IF=$FLAT_IF_FROM_LABEL
fi

# 定义变量
BRIDGE_NAME=${FLAT_BRIDGE:-flatbr0}
MTU=${MTU:-1500}

FLAT_IF_IP=$(ip addr show $FLAT_IF | grep 'inet\b' | awk '{print $2}')
FLAT_IF_MAC=$(ip addr show $FLAT_IF | grep ether | awk '{print $2}')
BRIDGE_IP=${FLAT_IF_IP}
BRIDGE_MAC=${FLAT_IF_MAC}
GW_IP=$(ip route show | grep default | awk '{print $3}')

# 网关检查
if [ -z $(ip route show | grep default | awk '{print $3}')  ]; then
    ip route add default via ${GW_IP}
fi

# 通过$BRIDGE_NAME判断flat容器是否为第一次运行，如果存在$BRIDGE_NAME，则需要保证exxx接口上没有IP
if ls '/sys/class/net' | grep -w $BRIDGE_NAME > /dev/null; then

    TEST_BRIDGE=$( ip addr show $BRIDGE_NAME | grep 'inet\b' | awk '{print $2}' )
    TEST_FLAT_IF=$( ip addr show $FLAT_IF | grep 'inet\b' | awk '{print $2}' )

    # 如果flatbr0有ip，并且exxx没有ip
    if [[ ! -z $TEST_BRIDGE ]] && [[ -z $TEST_FLAT_IF ]]; then
        exit 0
    fi

    # 如果flatbr0有ip，并且exxx有ip，则需要删除${BRIDGE_NAME}，再新建${BRIDGE_NAME}
    if [[ ! -z $TEST_BRIDGE ]] && [[ ! -z $TEST_FLAT_IF ]]; then
        ip link delete ${BRIDGE_NAME}

        ip link add ${BRIDGE_NAME} type bridge || true
        ip link set ${BRIDGE_NAME} address ${BRIDGE_MAC}
        ip addr del ${FLAT_IF_IP} dev ${FLAT_IF}
        ip addr add ${BRIDGE_IP} brd + dev ${BRIDGE_NAME}
        ip link set dev ${BRIDGE_NAME} up
        ip link set dev ${FLAT_IF} master ${BRIDGE_NAME}
        ip link set dev ${BRIDGE_NAME} mtu ${MTU}
    fi

else

    # 第一次运行flat容器
    ip link add ${BRIDGE_NAME} type bridge || true
    ip link set ${BRIDGE_NAME} address ${BRIDGE_MAC}
    ip addr del ${FLAT_IF_IP} dev ${FLAT_IF}
    ip addr add ${BRIDGE_IP} brd + dev ${BRIDGE_NAME}
    ip link set dev ${BRIDGE_NAME} up
    ip link set dev ${FLAT_IF} master ${BRIDGE_NAME}
    ip link set dev ${BRIDGE_NAME} mtu ${MTU}
fi