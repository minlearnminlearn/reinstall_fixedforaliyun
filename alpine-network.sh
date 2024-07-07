#!/bin/ash
# shellcheck shell=dash
# alpine / debian initrd 共用此脚本

mac_addr=$1
ipv4_addr=$2
ipv4_gateway=$3
ipv6_addr=$4
ipv6_gateway=$5
is_in_china=$6

if $is_in_china; then
    ipv4_dns1='119.29.29.29'
    ipv4_dns2='223.5.5.5'
    ipv6_dns1='2402:4e00::'
    ipv6_dns2='2400:3200::1'
else
    ipv4_dns1='1.1.1.1'
    ipv4_dns2='8.8.8.8'
    ipv6_dns1='2606:4700:4700::1111'
    ipv6_dns2='2001:4860:4860::8888'
fi

# 找到主网卡
# debian 11 initrd 没有 xargs awk
# debian 12 initrd 没有 xargs
get_ethx() {
    if false; then
        ip -o link | grep -i "$mac_addr" | awk '{print $2}' | cut -d: -f1
    else
        ip -o link | grep -i "$mac_addr" | cut -d' ' -f2 | cut -d: -f1
    fi
}

get_ipv4_gateway() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    ip -4 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_ipv6_gateway() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    ip -6 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_first_ipv4_addr() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    if false; then
        ip -4 -o addr show scope global dev "$ethx" | head -1 | awk '{print $4}'
    else
        ip -4 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9\.]*/[0-9]*'
    fi
}

get_first_ipv6_addr() {
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    if false; then
        ip -6 -o addr show scope global dev "$ethx" | head -1 | awk '{print $4}'
    else
        ip -6 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9a-f\:]*/[0-9]*'
    fi
}

is_have_ipv4_addr() {
    ip -4 addr show scope global dev "$ethx" | grep -q inet
}

is_have_ipv6_addr() {
    ip -6 addr show scope global dev "$ethx" | grep -q inet6
}

is_have_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | grep -q .
}

is_have_ipv6_gateway() {
    ip -6 route show default dev "$ethx" | grep -q .
}

is_have_ipv4() {
    is_have_ipv4_addr && is_have_ipv4_gateway
}

is_have_ipv6() {
    is_have_ipv6_addr && is_have_ipv6_gateway
}

add_missing_ipv4_config() {
    if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
        if ! is_have_ipv4_addr; then
            ip -4 addr add "$ipv4_addr" dev "$ethx"
        fi

        if ! is_have_ipv4_gateway; then
            # 如果 dhcp 无法设置onlink网关，那么在这里设置
            ip -4 route add default via "$ipv4_gateway" dev "$ethx" onlink
        fi
    fi
}

add_missing_ipv6_config() {
    if [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
        if ! is_have_ipv6_addr; then
            ip -6 addr add "$ipv6_addr" dev "$ethx"
        fi

        if ! is_have_ipv6_gateway; then
            # 如果 dhcp 无法设置onlink网关，那么在这里设置
            ip -6 route add default via "$ipv6_gateway" dev "$ethx" onlink
        fi
    fi
}

is_need_test_ipv4() {
    is_have_ipv4 && ! $ipv4_has_internet
}

is_need_test_ipv6() {
    is_have_ipv6 && ! $ipv6_has_internet
}

test_internet() {
    echo 'Testing Internet Connection...'

    # debian 没有 nslookup，因此用 ping
    for i in $(seq 5); do
        if is_need_test_ipv4 && ping -c1 -W5 -I "$ethx" "$ipv4_dns1" >/dev/null 2>&1; then
            echo "IPv4 has internet."
            ipv4_has_internet=true
        fi
        if is_need_test_ipv6 && ping -c1 -W5 -I "$ethx" "$ipv6_dns1" >/dev/null 2>&1; then
            echo "IPv6 has internet."
            ipv6_has_internet=true
        fi
        if ! is_need_test_ipv4 && ! is_need_test_ipv6; then
            break
        fi
        sleep 1
    done
}

flush_ipv4_config() {
    ip -4 addr flush scope global dev "$ethx"
    ip -4 route flush dev "$ethx"
}

flush_ipv6_config() {
    # 是否临时禁用 ra / slaac
    if [ "$1" = true ]; then
        echo 0 >"/proc/sys/net/ipv6/conf/$ethx/autoconf"
    fi

    ip -6 addr flush scope global dev "$ethx"
    ip -6 route flush dev "$ethx"
}

# dhcp v4 /v6
# debian / kali
if [ -f /usr/share/debconf/confmodule ]; then
    # shellcheck source=/dev/null
    . /usr/share/debconf/confmodule

    # 开启 ethx + dhcpv4/v6
    ethx=$(get_ethx)
    ip link set dev "$ethx" up
    sleep 1
    db_progress STEP 1

    # dhcpv4
    db_progress INFO netcfg/dhcp_progress
    udhcpc -i "$ethx" -f -q -n || true
    db_progress STEP 1

    # slaac + dhcpv6
    db_progress INFO netcfg/slaac_wait_title
    # https://salsa.debian.org/installer-team/netcfg/-/blob/master/autoconfig.c#L148
    cat <<EOF >/var/lib/netcfg/dhcp6c.conf
interface $ethx {
    send ia-na 0;
    request domain-name-servers;
    request domain-name;
    script "/lib/netcfg/print-dhcp6c-info";
};

id-assoc na 0 {
};
EOF
    dhcp6c -c /var/lib/netcfg/dhcp6c.conf "$ethx" || true
    sleep 10
    # kill-all-dhcp
    kill -9 "$(cat /var/run/dhcp6c.pid)" || true
    db_progress STEP 1

    # 静态 + 检测网络提示
    db_subst netcfg/link_detect_progress interface "$ethx"
    db_progress INFO netcfg/link_detect_progress
else
    # alpine
    ethx=$(get_ethx)
    echo "$ethx"
    ip link set dev "$ethx" up
    sleep 1
    udhcpc -i "$ethx" -f -q -n || true
    udhcpc6 -i "$ethx" -f -q -n || true
fi

# 等待slaac
# 有ipv6地址就跳过，不管是slaac或者dhcpv6
# 因为会在trans里判断
# 这里等待5秒就够了，因为之前尝试获取dhcp6也用了一段时间
for i in $(seq 5 -1 0); do
    is_have_ipv6 && break
    echo "waiting slaac for ${i}s"
    sleep 1
done

# 记录是否有动态地址
# 由于还没设置静态ip，所以有条目表示有动态地址
is_have_ipv4_addr && dhcpv4=true || dhcpv4=false
is_have_ipv6_addr && dhcpv6_or_slaac=true || dhcpv6_or_slaac=false

# 设置静态地址，或者设置udhcpc无法设置的网关
add_missing_ipv4_config
add_missing_ipv6_config

# 检查 ipv4/ipv6 是否连接联网
ipv4_has_internet=false
ipv6_has_internet=false

test_internet

# 处理云电脑 dhcp 获取的地址无法上网
if $dhcpv4 && ! $ipv4_has_internet &&
    [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ] &&
    { ! [ "$ipv4_addr" = "$(get_first_ipv4_addr)" ] || ! [ "$ipv4_gateway" = "$(get_ipv4_gateway)" ]; }; then
    echo "DHCPv4 can't access Internet. And not match static IPv4 Address or Gateway."
    flush_ipv4_config
    add_missing_ipv4_config
    test_internet
    if $ipv4_has_internet; then
        dhcpv4=false
    fi
fi

should_disable_ra_slaac=false
# 处理部分商家 slaac / dhcpv6 获取的 ip 无法上网
if $dhcpv6_or_slaac && ! $ipv6_has_internet &&
    [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ] &&
    { ! [ "$ipv6_addr" = "$(get_first_ipv6_addr)" ] || ! [ "$ipv6_gateway" = "$(get_ipv6_gateway)" ]; }; then
    echo "SLAAC can't access Internet. And not match static IPv6 Address or Gateway."
    flush_ipv6_config true
    add_missing_ipv6_config
    test_internet
    if $ipv6_has_internet; then
        dhcpv6_or_slaac=false
        should_disable_ra_slaac=true
    fi
fi

# 等待 udhcpc 创建 /etc/resolv.conf
# 好像只有 dhcpv4 会创建 resolv.conf
if { $dhcpv4 || $dhcpv6_or_slaac; } && [ ! -e /etc/resolv.conf ]; then
    echo "Waiting for /etc/resolv.conf..."
    sleep 5
fi

# 要删除不联网协议的ip，因为
# 1 甲骨文云管理面板添加ipv6地址然后取消
#   依然会分配ipv6地址，但ipv6没网络
#   此时alpine只会用ipv6下载apk，而不用会ipv4下载
# 2 有ipv4地址但没有ipv4网关的情况(vultr)，aria2会用ipv4下载
if $ipv4_has_internet && ! $ipv6_has_internet; then
    echo 0 >"/proc/sys/net/ipv6/conf/$ethx/accept_ra"
    ip -6 addr flush scope global dev "$ethx"
elif ! $ipv4_has_internet && $ipv6_has_internet; then
    ip -4 addr flush scope global dev "$ethx"
fi

# 如果联网了，但没获取到默认 DNS，则添加我们的 DNS
if $ipv4_has_internet && ! grep '\.' /etc/resolv.conf; then
    echo "nameserver $ipv4_dns1" >>/etc/resolv.conf
    echo "nameserver $ipv4_dns2" >>/etc/resolv.conf
fi
if $ipv6_has_internet && ! grep ':' /etc/resolv.conf; then
    echo "nameserver $ipv6_dns1" >>/etc/resolv.conf
    echo "nameserver $ipv6_dns2" >>/etc/resolv.conf
fi

# 传参给 trans.start
netconf="/dev/netconf/$ethx"
mkdir -p "$netconf"
$dhcpv4 && echo 1 >"$netconf/dhcpv4" || echo 0 >"$netconf/dhcpv4"
$should_disable_ra_slaac && echo 1 >"$netconf/should_disable_ra_slaac" || echo 0 >"$netconf/should_disable_ra_slaac"
$is_in_china && echo 1 >"$netconf/is_in_china" || echo 0 >"$netconf/is_in_china"
echo "$ethx" >"$netconf/ethx"
echo "$mac_addr" >"$netconf/mac_addr"
echo "$ipv4_addr" >"$netconf/ipv4_addr"
echo "$ipv4_gateway" >"$netconf/ipv4_gateway"
echo "$ipv6_addr" >"$netconf/ipv6_addr"
echo "$ipv6_gateway" >"$netconf/ipv6_gateway"
$ipv4_has_internet && echo 1 >"$netconf/ipv4_has_internet" || echo 0 >"$netconf/ipv4_has_internet"
$ipv6_has_internet && echo 1 >"$netconf/ipv6_has_internet" || echo 0 >"$netconf/ipv6_has_internet"
