#!/bin/bash
# ---------------------------------------------------------------------
# 执行脚本时添加-d参数则会删除未使用的网络接口，不加参数默认只打印出未使用的网络接口。
# ---------------------------------------------------------------------

VETH_INUSE=()
VETH_UNUSED=()
VETH_HOST=()
VETH_ALL=()

# 如果不存在，创建netns目录
mkdir -p /var/run/netns

# 将所有进程命名空间添加到netns
for i in /proc/[0-9]*/ns/net; 
do
    ln -s $i /var/run/netns/proc$(echo $i | cut -d/ -f3)
done

# 移除不关联的网络命名空间
for i in $(ip netns | grep ^proc | grep -v id); 
do
    rm -f /var/run/netns/${i}
done

# 移除子进程
for i in $(ip netns | grep ^proc | awk 'a[$3]++ {print $1}'); 
do
    rm -f /var/run/netns/${i}
done


# 通过容器ID去查询容器网络接口
veth_container() {
    CONTAINER_NETWORK_MODE=$( docker inspect -f "{{ .HostConfig.NetworkMode }}" $1 )
    CONTAINER_CONFIG_HOSTNAME=$( docker inspect -f "{{ .Config.Hostname }}" $1 )

    if [ "$CONTAINER_NETWORK_MODE" == "host" ]||[ "$CONTAINER_CONFIG_HOSTNAME" == "$HOSTNAME" ]; then
        echo 'host'
    else
        CONTAINER_PID=$( docker inspect -f '{{.State.Pid}}' "${1}" )
        CONTAINER_IF_INDEX=$( nsenter -t ${CONTAINER_PID} -n ip link | sed -n -e 's/.*eth0@if\([0-9]*\):.*/\1/p' )
        ip -o link | grep ^${CONTAINER_IF_INDEX} | sed -n -e 's/.*\(veth[[:alnum:]]*@if[[:digit:]]*\).*/\1/p' | awk -F'@' '{print $1}'
    fi
}

# 查询所有正在被容器使用的网络接口
CONTAINER_ID_LIST=$( docker ps | grep -v -E '/pause|CONTAINER' | awk '{print $1}' | head -n10 )

for CONTAINER_ID in ${CONTAINER_ID_LIST};
do
    if [ "$( veth_container ${CONTAINER_ID} )" != "host" ]; then
        VETH_INUSE=$( eval echo "${VETH_INUSE} $( veth_container ${CONTAINER_ID} )" )
        echo "${CONTAINER_ID} $(veth_container ${CONTAINER_ID}) " >> container-id-veth.txt
    else
        CONTAINER_VETH_HOST=$( eval echo "${CONTAINER_VETH_HOST} ${CONTAINER_ID}" )
    fi
done

# 列出所有网络接口
VETH_ALL=$( ip link | grep veth | awk -F ":" '{print $2}' | awk -F'@' '{print $1}' | head -n10 );

# 判断未使用的网络接口
for veth in ${VETH_ALL};
do  
    if ! echo "${VETH_INUSE[@]}" | grep -w ${veth} &>/dev/null; then 
        VETH_UNUSED=$( eval echo "${VETH_UNUSED} ${veth}" )
    fi   
done

# 打印未使用的网络接口
echo 'Prints unused network interfaces'
echo "${VETH_UNUSED[@]}"

echo 'Prints host network container'
echo "${CONTAINER_VETH_HOST[@]}"

# 打印容器ID与网络接口的对应关系
#cat container-id-veth.txt

# 添加 -d 参数删除未使用的网络接口;
if [ "$1" == "-d" ]; then
   for veth_unused in "${VETH_UNUSED[@]}";
   do
      ip link set ${veth_unused} down
      ip link delete ${veth_unused}
   done
fi