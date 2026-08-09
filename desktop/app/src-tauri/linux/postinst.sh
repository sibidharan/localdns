#!/bin/sh
set -e
systemctl daemon-reload || true
systemctl enable --now localdns-agentd.service || true
