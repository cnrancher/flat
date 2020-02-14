#!/bin/bash

set -ex

LABEL="io.rancher.network.l2flat.interface"
METADATA_ADDRESS=${RANCHER_METADATA_ADDRESS:-169.254.169.250}
FLAT_CONFIG_DIR='/opt/cni-driver/l2-flat.d'

while ! curl -s -f http://${METADATA_ADDRESS}/2016-07-29/self/host; do
    echo Waiting for metadata
    sleep 1
done

FLAT_IF_FROM_LABEL=$( curl -s http://${METADATA_ADDRESS}/2016-07-29/self/host/labels/${LABEL} )

if [ "$( echo ${FLAT_IF_FROM_LABEL} | grep "Not found" )" != ""  ]; then
    FLAT_IF=${FLAT_IF:-eth0}
else
    echo "Used the host label..."
    FLAT_IF=${FLAT_IF_FROM_LABEL}
fi

# 定义变量
BRIDGE_NAME=${FLAT_BRIDGE:-flatbr0}
MTU=${MTU:-1500}

FLAT_IF_IP=$( ip addr show ${FLAT_IF} | grep 'inet\b' | awk '{print $2}' )
FLAT_IF_MAC=$( ip addr show ${FLAT_IF} | grep ether | awk '{print $2}' )
BRIDGE_IP=${FLAT_IF_IP}
BRIDGE_MAC=${FLAT_IF_MAC}
GW_IP=$( ip route show | grep default | awk '{print $3}' )

# 网关检查
if [ -z $( ip route show | grep default | awk '{print $3}') ]; then
    ip route add default via ${GW_IP}
fi

touch ${FLAT_CONFIG_DIR}/bridge-ip
touch ${FLAT_CONFIG_DIR}/bridge-mac

# 通过 检查 ${BRIDGE_NAME} 是否存在来判断 flat 容器是否为第一次运行
if ls '/sys/class/net' | grep -w ${BRIDGE_NAME} > /dev/null; then
    # 当前存在 ${BRIDGE_NAME} 接口，则需要检查 ${FLAT_IF} 接口上是否有 ip
    TEST_BRIDGE=$( ip addr show ${BRIDGE_NAME} | grep 'inet\b' | awk '{print $2}' )
    TEST_FLAT_IF=$( ip addr show ${FLAT_IF} | grep 'inet\b' | awk '{print $2}' )

    # 如果 ${BRIDGE_NAME} 有 ip，${FLAT_IF} 没有 ip，则判断容器为非第一次运行，则跳过接口初始化
    if [[ ! -z ${TEST_BRIDGE} ]] && [[ -z ${TEST_FLAT_IF} ]]; then
        exit 0
    fi

    # 如果 ${BRIDGE_NAME} 有 ip，${FLAT_IF} 有 ip，则需要先删除再重建 ${BRIDGE_NAME}
    if [[ ! -z ${TEST_BRIDGE} ]] && [[ ! -z ${TEST_FLAT_IF} ]]; then
        ip link delete ${BRIDGE_NAME}

        ip link add ${BRIDGE_NAME} type bridge || true
        ip link set ${BRIDGE_NAME} address ${BRIDGE_MAC}
        ip addr del ${FLAT_IF_IP} dev ${FLAT_IF}
        ip addr add ${BRIDGE_IP} brd + dev ${BRIDGE_NAME}
        ip link set dev ${BRIDGE_NAME} up
        ip link set dev ${FLAT_IF} master ${BRIDGE_NAME}
        ip link set dev ${BRIDGE_NAME} mtu ${MTU}
    fi

    # 如果 ${BRIDGE_NAME} 没有 ip，${FLAT_IF} 有 ip，则先删除再重建 ${BRIDGE_NAME}
    if [[ -z ${TEST_BRIDGE} ]] && [[ ! -z ${TEST_FLAT_IF} ]]; then
        ip link delete ${BRIDGE_NAME}

        ip link add ${BRIDGE_NAME} type bridge || true
        ip link set ${BRIDGE_NAME} address ${BRIDGE_MAC}
        ip addr del ${FLAT_IF_IP} dev ${FLAT_IF}
        ip addr add ${BRIDGE_IP} brd + dev ${BRIDGE_NAME}
        ip link set dev ${BRIDGE_NAME} up
        ip link set dev ${FLAT_IF} master ${BRIDGE_NAME}
        ip link set dev ${BRIDGE_NAME} mtu ${MTU}
    fi

    # 如果 ${BRIDGE_NAME} 没有 ip，${FLAT_IF} 没有 ip，
    # 先判断 ${FLAT_CONFIG_DIR} 中是否有 ip 和 mac 地址备份，如果有直接拿来使用
    if [[ -z ${TEST_BRIDGE} ]] && [[ -z ${TEST_FLAT_IF} ]]; then
        TEST_BRIDGE_IP_BAK=$( cat ${FLAT_CONFIG_DIR}/bridge-ip )
        TEST_BRIDGE_MAC_BAK=$( cat ${FLAT_CONFIG_DIR}/bridge-mac )

        # 如果 ${TEST_BRIDGE_IP_BAK} 和 ${TEST_BRIDGE_MAC_BAK} 同时存在，则直接使用备份 ip 和 mac 地址
        if [[ ! -z ${TEST_BRIDGE_IP_BAK} ]] && [[ ! -z ${TEST_BRIDGE_MAC_BAK} ]]; then
            ip link delete ${BRIDGE_NAME}

            ip link add ${BRIDGE_NAME} type bridge || true
            ip link set ${BRIDGE_NAME} address ${TEST_BRIDGE_MAC_BAK}
            ip addr add ${TEST_BRIDGE_IP_BAK} brd + dev ${BRIDGE_NAME}
            ip link set dev ${BRIDGE_NAME} up
            ip link set dev ${FLAT_IF} master ${BRIDGE_NAME}
            ip link set dev ${BRIDGE_NAME} mtu ${MTU}
        else
            exit 1
        fi
    fi
else
    # 当前没有 ${BRIDGE_NAME} 接口，则判断为第一次运行 flat 容器
    # 第一次运行，对 ${BRIDGE_IP 和 ${BRIDGE_MAC} 做一个备份
    echo ${BRIDGE_IP} > ${FLAT_CONFIG_DIR}/bridge-ip
    echo ${BRIDGE_MAC} > ${FLAT_CONFIG_DIR}/bridge-mac

    ip link add ${BRIDGE_NAME} type bridge || true
    ip link set ${BRIDGE_NAME} address ${BRIDGE_MAC}
    ip addr del ${FLAT_IF_IP} dev ${FLAT_IF}
    ip addr add ${BRIDGE_IP} brd + dev ${BRIDGE_NAME}
    ip link set dev ${BRIDGE_NAME} up
    ip link set dev ${FLAT_IF} master ${BRIDGE_NAME}
    ip link set dev ${BRIDGE_NAME} mtu ${MTU}
fi