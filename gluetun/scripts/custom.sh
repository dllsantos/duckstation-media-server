#!/bin/sh
echo "[Custom Script] Aplicando regra iptables UDP 6881..."
iptables -A OUTPUT -p udp --sport 6881 -j ACCEPT
