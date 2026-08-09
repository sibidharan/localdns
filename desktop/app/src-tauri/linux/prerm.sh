#!/bin/sh
set -e
# Stopping the agent deletes the localdns0 link, which reverts the
# systemd-resolved routing with it.
systemctl disable --now localdns-agentd.service || true
systemctl daemon-reload || true
