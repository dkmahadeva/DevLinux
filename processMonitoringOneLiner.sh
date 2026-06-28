# Replace "sleep" with your command/process you want to monitor.
date ; for i in {1..60}; do echo "Second $i: "; podman top centos1 | grep -w "sleep"; sleep 1; done
