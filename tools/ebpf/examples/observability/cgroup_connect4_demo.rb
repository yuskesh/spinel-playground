# E105 demo: cgroup/connect4 — deny outbound IPv4 connections to port 9999 from
# every process in the cgroup, allow the rest. A blocked connect() gets -EPERM.
def cgroup__connect4__guard
  if sock_addr_port() == 9999
    0
  else
    1
  end
end
puts "[E105] cgroup/connect4 deny-port-9999 attached"
sleep 3600
