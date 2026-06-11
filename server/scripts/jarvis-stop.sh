#!/bin/bash
U=gui/$(id -u)
for s in com.jarvis.voice com.jarvis.dashboard; do launchctl bootout $U/$s 2>/dev/null; done
echo "stopped"
